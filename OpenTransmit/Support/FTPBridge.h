#ifndef FTPBridge_h
#define FTPBridge_h
#include <stddef.h>
typedef int (*OTFTPCancel)(void *context);
// mode: 0 MLSD, 1 download, 2 upload, 3 commands. Never accepts raw user commands.
int ot_ftp_request(const char *url, const char *username, const char *password,
                   int tls, int mode, const char *file_path,
                   const char *command1, const char *command2,
                   OTFTPCancel canceled, void *context, long *reply);
#endif
