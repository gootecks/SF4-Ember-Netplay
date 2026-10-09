/* Wine boundary probe for the SF4 Ember macOS engine spike (issue #4).
 * Build: i686-w64-mingw32-gcc -O2 -static winsock_probe.c -o winsock_probe.exe -lws2_32
 * Modes:
 *   udp-send <port> <count>     bind 127.0.0.1:0 (as GGPO), sendto 127.0.0.1:port
 *   udp-echo <port> <seconds>   bind 127.0.0.1:port, echo datagrams back to sender
 *   tcp-connect <port> <msg>    connect to a native listener, send msg, read reply
 *   tcp-listen <port> <seconds> accept a native connect, read, reply "pong"
 *   pipe                        try \\.\pipe\discord-ipc-0..9, handshake if one opens
 * Each result prints: RESULT <test> PASS|FAIL <detail>
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void result(const char* test, int pass, const char* fmt, ...) {
	char buf[512]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
	printf("RESULT %s %s %s\n", test, pass ? "PASS" : "FAIL", buf); fflush(stdout);
}

static SOCKET make(int type, int proto, unsigned short port, const char* test) {
	SOCKET s = socket(AF_INET, type, proto);
	if (s == INVALID_SOCKET) { result(test, 0, "socket err=%d", WSAGetLastError()); return s; }
	return s;
}

static void loopback(struct sockaddr_in* a, unsigned short port) {
	memset(a, 0, sizeof *a); a->sin_family = AF_INET;
	a->sin_addr.s_addr = htonl(INADDR_LOOPBACK); a->sin_port = htons(port);
}

static int bind_loopback(SOCKET s, unsigned short port, const char* test, unsigned short* bound) {
	struct sockaddr_in a; loopback(&a, port);
	if (bind(s, (struct sockaddr*)&a, sizeof a) != 0) { result(test, 0, "bind err=%d", WSAGetLastError()); return -1; }
	int n = sizeof a;
	if (getsockname(s, (struct sockaddr*)&a, &n) != 0) { result(test, 0, "getsockname err=%d", WSAGetLastError()); return -1; }
	if (bound) *bound = ntohs(a.sin_port);
	return 0;
}

static int wait_readable(SOCKET s, int ms) {
	fd_set r; FD_ZERO(&r); FD_SET(s, &r);
	struct timeval tv = { ms / 1000, (ms % 1000) * 1000 };
	return select(0, &r, NULL, NULL, &tv);
}

static int udp_send(unsigned short port, int count) {
	SOCKET s = make(SOCK_DGRAM, IPPROTO_UDP, 0, "udp-wine-to-native"); if (s == INVALID_SOCKET) return 1;
	unsigned short local = 0; if (bind_loopback(s, 0, "udp-wine-to-native", &local)) return 1;
	struct sockaddr_in to; loopback(&to, port); int sent = 0;
	for (int i = 0; i < count; i++) {
		char msg[64]; int n = snprintf(msg, sizeof msg, "ember-m0-udp-%d", i);
		if (sendto(s, msg, n, 0, (struct sockaddr*)&to, sizeof to) == n) sent++;
		Sleep(50);
	}
	printf("local_port=%u\n", local);
	result("udp-wine-to-native-send", sent == count, "sent=%d/%d local_port=%u dest=127.0.0.1:%u", sent, count, local, port);
	return sent != count;
}

static int udp_echo(unsigned short port, int seconds) {
	SOCKET s = make(SOCK_DGRAM, IPPROTO_UDP, port, "udp-native-to-wine"); if (s == INVALID_SOCKET) return 1;
	if (bind_loopback(s, port, "udp-native-to-wine", NULL)) return 1;
	printf("READY udp-echo %u\n", port); fflush(stdout);
	int got = 0, replied = 0; DWORD end = GetTickCount() + seconds * 1000;
	while ((int)(end - GetTickCount()) > 0) {
		if (wait_readable(s, 200) <= 0) continue;
		char buf[1500]; struct sockaddr_in from; int fl = sizeof from;
		int n = recvfrom(s, buf, sizeof buf, 0, (struct sockaddr*)&from, &fl);
		if (n <= 0) continue;
		got++;
		if (sendto(s, buf, n, 0, (struct sockaddr*)&from, fl) == n) replied++;
		if (got >= 3) break;
	}
	result("udp-native-to-wine", got > 0 && replied == got, "received=%d replied=%d", got, replied);
	return !(got > 0 && replied == got);
}

static int tcp_connect(unsigned short port, const char* msg) {
	SOCKET s = make(SOCK_STREAM, IPPROTO_TCP, 0, "tcp-wine-to-native"); if (s == INVALID_SOCKET) return 1;
	struct sockaddr_in a; loopback(&a, port);
	if (connect(s, (struct sockaddr*)&a, sizeof a) != 0) { result("tcp-wine-to-native", 0, "connect err=%d", WSAGetLastError()); return 1; }
	int n = (int)strlen(msg);
	if (send(s, msg, n, 0) != n) { result("tcp-wine-to-native", 0, "send err=%d", WSAGetLastError()); return 1; }
	char buf[256] = {0}; int got = 0;
	if (wait_readable(s, 4000) > 0) got = recv(s, buf, sizeof buf - 1, 0);
	result("tcp-wine-to-native", got > 0, "sent=%d reply_bytes=%d reply=%.*s", n, got < 0 ? 0 : got, got > 0 ? got : 0, buf);
	return got <= 0;
}

static int tcp_listen(unsigned short port, int seconds) {
	SOCKET l = make(SOCK_STREAM, IPPROTO_TCP, port, "tcp-native-to-wine"); if (l == INVALID_SOCKET) return 1;
	if (bind_loopback(l, port, "tcp-native-to-wine", NULL)) return 1;
	if (listen(l, 1) != 0) { result("tcp-native-to-wine", 0, "listen err=%d", WSAGetLastError()); return 1; }
	printf("READY tcp-listen %u\n", port); fflush(stdout);
	if (wait_readable(l, seconds * 1000) <= 0) { result("tcp-native-to-wine", 0, "no connection within %ds", seconds); return 1; }
	SOCKET c = accept(l, NULL, NULL);
	if (c == INVALID_SOCKET) { result("tcp-native-to-wine", 0, "accept err=%d", WSAGetLastError()); return 1; }
	char buf[256] = {0}; int got = 0;
	if (wait_readable(c, 4000) > 0) got = recv(c, buf, sizeof buf - 1, 0);
	int sent = send(c, "pong", 4, 0);
	closesocket(c);
	result("tcp-native-to-wine", got > 0 && sent == 4, "received=%d msg=%.*s replied=%d", got < 0 ? 0 : got, got > 0 ? got : 0, buf, sent);
	return !(got > 0 && sent == 4);
}

static int pipe_probe(void) {
	int opened = -1, replied = 0; char detail[512] = ""; size_t dl = 0;
	for (int i = 0; i < 10; i++) {
		wchar_t name[64]; swprintf(name, 64, L"\\\\.\\pipe\\discord-ipc-%d", i);
		HANDLE h = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
		DWORD err = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
		dl += snprintf(detail + dl, sizeof detail - dl, "%d:%lu ", i, err);
		printf("pipe discord-ipc-%d CreateFileW %s GetLastError=%lu\n", i, h == INVALID_HANDLE_VALUE ? "failed" : "ok", err);
		if (h == INVALID_HANDLE_VALUE) continue;
		opened = i;
		const char* json = "{\"v\":1,\"client_id\":\"0\"}"; DWORD jl = (DWORD)strlen(json), w = 0;
		unsigned char frame[8 + 64]; DWORD op = 0; memcpy(frame, &op, 4); memcpy(frame + 4, &jl, 4); memcpy(frame + 8, json, jl);
		BOOL ok = WriteFile(h, frame, 8 + jl, &w, NULL);
		unsigned char rb[512]; DWORD rd = 0;
		if (ok) {
			DWORD avail = 0;
			for (int t = 0; t < 20 && !avail; t++) { if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) break; if (!avail) Sleep(100); }
			if (avail) ReadFile(h, rb, sizeof rb, &rd, NULL);
		}
		printf("handshake write=%d bytes=%lu reply_bytes=%lu\n", ok, w, rd);
		replied = rd > 0; CloseHandle(h); break;
	}
	result("discord-pipe-to-native", opened >= 0, "opened_index=%d handshake_reply=%d errors=[%s]", opened, replied, detail);
	return opened < 0;
}

int main(int argc, char** argv) {
	WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
	if (argc >= 2 && !strcmp(argv[1], "pipe")) return pipe_probe();
	if (argc >= 4 && !strcmp(argv[1], "udp-send")) return udp_send((unsigned short)atoi(argv[2]), atoi(argv[3]));
	if (argc >= 4 && !strcmp(argv[1], "udp-echo")) return udp_echo((unsigned short)atoi(argv[2]), atoi(argv[3]));
	if (argc >= 4 && !strcmp(argv[1], "tcp-connect")) return tcp_connect((unsigned short)atoi(argv[2]), argv[3]);
	if (argc >= 4 && !strcmp(argv[1], "tcp-listen")) return tcp_listen((unsigned short)atoi(argv[2]), atoi(argv[3]));
	fprintf(stderr, "usage: udp-send|udp-echo|tcp-connect|tcp-listen <port> <arg> | pipe\n");
	return 2;
}
