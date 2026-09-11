"""Loopback-only SFTP fixtures. Never connects to a cloud server or reads SSH user configuration."""
import errno
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import paramiko


class Auth(paramiko.ServerInterface):
    def __init__(self, password, public_key):
        self.password, self.public_key = password, public_key

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == "test" and password == self.password else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "test" and key == self.public_key else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password,publickey"

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *, root):
        super().__init__(server)
        self.root = Path(root).resolve()

    def path(self, path):
        candidate = self.root / path.lstrip("/")
        if not candidate.resolve().is_relative_to(self.root):
            raise PermissionError(errno.EACCES, "Outside test root")
        if path == "/denied" or path.startswith("/denied/"):
            raise PermissionError(errno.EACCES, "Deliberate fixture denial")
        return candidate

    def list_folder(self, path):
        try:
            result = []
            for item in self.path(path).iterdir():
                attr = paramiko.SFTPAttributes.from_stat(item.lstat())
                attr.filename = item.name
                result.append(attr)
            return result
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def lstat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.path(path).lstat())
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def open(self, path, flags, attr):
        try:
            fd = os.open(self.path(path), flags, 0o600)
            mode = "r+b" if flags & os.O_RDWR else "wb" if flags & os.O_WRONLY else "rb"
            file = os.fdopen(fd, mode)
            handle = paramiko.SFTPHandle(flags)
            handle.readfile = file
            handle.writefile = file
            return handle
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def mkdir(self, path, attr):
        try:
            self.path(path).mkdir()
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def remove(self, path):
        try:
            self.path(path).unlink()
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def rename(self, oldpath, newpath):
        try:
            source, target = self.path(oldpath), self.path(newpath)
            if source.name.endswith(".partial") and target.name == "fail-commit":
                return paramiko.SFTP_FAILURE
            if target.exists():
                return paramiko.SFTP_FAILURE
            source.rename(target)
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)


def key_at(path):
    subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)], check=True)
    return paramiko.Ed25519Key(filename=str(path))


def serve(root, key, password, public_key):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(10)
    port = listener.getsockname()[1]
    transports = []

    def accept():
        while True:
            try:
                sock, _ = listener.accept()
            except OSError:
                return
            transport = paramiko.Transport(sock)
            transports.append(transport)
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files, root=root)
            def handshake(transport=transport):
                try:
                    transport.start_server(server=Auth(password, public_key))
                except (EOFError, paramiko.SSHException):
                    transport.close()
            threading.Thread(target=handshake, daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    return port, listener, transports


with tempfile.TemporaryDirectory(prefix="OpenTransmit-SFTP-") as temp:
    root = Path(temp)
    roots = [root / "server-a", root / "server-b"]
    for folder in roots:
        folder.mkdir()
        (folder / "denied").mkdir()
        (folder / "fail-commit").write_text("original-backup")
    (roots[0] / "many").mkdir()
    for i in range(150):
        (roots[0] / "many" / str(i)).write_text(str(i))
    (roots[0] / "link").symlink_to("many")
    key_a, key_b = key_at(root / "host-a"), key_at(root / "host-b")
    user_key = key_at(root / "user-key")
    password = uuid.uuid4().hex
    a = serve(roots[0], key_a, password, user_key)
    b = serve(roots[1], key_b, password, user_key)
    config = dict(portA=a[0], portB=b[0], hostKeyA=f"{key_a.get_name()} {key_a.get_base64()}",
                  hostKeyB=f"{key_b.get_name()} {key_b.get_base64()}", password=password,
                  privateKey=str(root / "user-key"), root=str(root / "local"))
    config_path = root / "config.json"
    config_path.write_text(json.dumps(config))
    config_path.chmod(0o600)
    try:
        if sys.argv[1] == "--serve":
            print(str(config_path), flush=True)
            while True:
                time.sleep(1)
        else:
            result = subprocess.run([sys.argv[1], str(config_path)], timeout=180)
            sys.exit(result.returncode)
    finally:
        for _, listener, transports in (a, b):
            listener.close()
            for transport in transports:
                transport.close()
