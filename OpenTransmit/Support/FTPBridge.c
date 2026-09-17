#include "FTPBridge.h"
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/stat.h>
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
struct Progress { OTFTPCancel canceled; void *context; };
static int progress(void *p, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    struct Progress *state = p;
    return state->canceled(state->context);
}
int ot_ftp_request(const char *url, const char *username, const char *password,
                   int tls, int mode, const char *file_path, long long offset, long long length,
                   const char *command1, const char *command2,
                   OTFTPCancel canceled, void *context, long *reply) {
    pthread_once(&initialized, initialize);
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;
    FILE *file = NULL;
    struct curl_slist *commands = NULL;
    struct Progress state = { canceled, context };
    CURLcode result = CURLE_OK;
#define SET(option, value) do { result = curl_easy_setopt(curl, option, value); if (result) goto cleanup; } while (0)
    SET(CURLOPT_URL, url);
    SET(CURLOPT_USERNAME, username);
    SET(CURLOPT_PASSWORD, password);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_PROTOCOLS_STR, "ftp");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT, 15L);
    SET(CURLOPT_FTP_RESPONSE_TIMEOUT, 30L);
    SET(CURLOPT_LOW_SPEED_LIMIT, 1L);
    SET(CURLOPT_LOW_SPEED_TIME, 30L);
    SET(CURLOPT_FTP_USE_EPSV, 1L);
    SET(CURLOPT_FTP_SKIP_PASV_IP, 1L);
    SET(CURLOPT_USE_SSL, tls ? (long)CURLUSESSL_ALL : (long)CURLUSESSL_NONE);
    SET(CURLOPT_FTPSSLAUTH, (long)CURLFTPAUTH_TLS);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
#ifdef OT_FTP_TESTING
    // Test binary only: trust an ephemeral fixture CA without modifying macOS trust.
    const char *ca = getenv("OT_FTP_TEST_CA");
    if (ca && ca[0]) { SET(CURLOPT_CAINFO, ca); }
#endif
    SET(CURLOPT_SSLVERSION, (long)CURL_SSLVERSION_TLSv1_2);
    SET(CURLOPT_NOPROGRESS, 0L);
    SET(CURLOPT_XFERINFOFUNCTION, progress);
    SET(CURLOPT_XFERINFODATA, &state);
    if (offset < 0 || length < 0) { result = CURLE_BAD_FUNCTION_ARGUMENT; goto cleanup; }
    if (mode == 1 && length > 0) {
        char range[96];
        snprintf(range, sizeof(range), "%lld-%lld", offset, offset + length - 1);
        SET(CURLOPT_RANGE, range);
    } else if (mode == 1 && offset > 0) {
        SET(CURLOPT_RESUME_FROM_LARGE, (curl_off_t)offset);
    }
    if (mode != 3) {
        file = fopen(file_path, mode == 2 ? "rb" : "wb");
        if (!file) { result = CURLE_WRITE_ERROR; goto cleanup; }
        if (mode == 2) {
            struct stat st;
            if (fstat(fileno(file), &st)) { result = CURLE_READ_ERROR; goto cleanup; }
            SET(CURLOPT_UPLOAD, 1L);
            SET(CURLOPT_READDATA, file);
            if (offset > st.st_size || fseeko(file, (off_t)offset, SEEK_SET)) { result = CURLE_READ_ERROR; goto cleanup; }
            // Explicitly position the input and append only the verified suffix.
            if (offset > 0) { SET(CURLOPT_APPEND, 1L); }
            SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)(st.st_size - offset));
        } else {
            SET(CURLOPT_WRITEDATA, file);
            if (mode == 0) { SET(CURLOPT_CUSTOMREQUEST, "MLSD"); }
        }
    } else {
        commands = curl_slist_append(commands, command1);
        if (command2 && command2[0]) commands = curl_slist_append(commands, command2);
        SET(CURLOPT_QUOTE, commands);
        SET(CURLOPT_NOBODY, 1L);
    }
    result = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, reply);
cleanup:
    if (file && fclose(file) && result == CURLE_OK) result = CURLE_WRITE_ERROR;
    curl_slist_free_all(commands);
    curl_easy_cleanup(curl);
    return (int)result;
}
