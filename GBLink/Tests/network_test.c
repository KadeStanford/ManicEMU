// SPDX-License-Identifier: AGPL-3.0-or-later
// Real loopback TCP fault harness for the *same* native core, envelope and
// sequence gate as the iOS frontend. Does not claim to test MCSession/iOS Wi-Fi.
#include "fixtures.h"
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
static int read_all(int fd, uint8_t *data, size_t size) {
    while (size) {
        ssize_t n = recv(fd, data, size, 0);
        if (n <= 0) return 0;
        data += n; size -= n;
    } return 1;
}
static void write_all(int fd, const uint8_t *data, size_t size) {
    while (size) { ssize_t n = send(fd, data, size, 0); CHECK(n > 0); data += n; size -= n; }
}
static int connect_to(struct sockaddr_in *address) {
    int fd = socket(AF_INET, SOCK_STREAM, 0); CHECK(fd >= 0);
    CHECK(!connect(fd, (struct sockaddr *)address, sizeof(*address))); return fd;
}
static double now(void) { struct timespec t; CHECK(!clock_gettime(CLOCK_MONOTONIC, &t)); return t.tv_sec + t.tv_nsec / 1e9; }
int main(void) {
    signal(SIGPIPE, SIG_IGN); fixtures();
    int listener = socket(AF_INET, SOCK_STREAM, 0); CHECK(listener >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    CHECK(!bind(listener, (struct sockaddr *)&address, sizeof(address)));
    socklen_t length = sizeof(address); CHECK(!getsockname(listener, (struct sockaddr *)&address, &length));
    CHECK(!listen(listener, 1));
    pid_t child = fork(); CHECK(child >= 0);
    if (!child) {
        close(listener);
        int fd = connect_to(&address);
        uint8_t request[17], response[16 + MGL_PIXELS * 2], key = 16; MGLPacket packet;
        for (uint64_t sequence = 0; sequence < 4; sequence++) {
            usleep(20000); // Network latency/backpressure must delay wall time, not GB serial time.
            CHECK(mgl_encode(request, sizeof(request), MGL_INPUT, sequence, &key, 1));
            write_all(fd, request, 1); usleep(1000); write_all(fd, request + 1, 16);
            CHECK(read_all(fd, response, sizeof(response)));
            CHECK(mgl_decode(response, sizeof(response), &packet));
            CHECK(packet.type == MGL_FRAME && packet.sequence == sequence + 1);
        }
        CHECK(mgl_encode(request, sizeof(request), MGL_INPUT, 4, &key, 1));
        write_all(fd, request, 5); close(fd); // Drop halfway through an input request.
        usleep(80000); fd = connect_to(&address);
        write_all(fd, request, sizeof(request));
        CHECK(read_all(fd, response, sizeof(response)));
        CHECK(mgl_decode(response, sizeof(response), &packet) && packet.sequence == 5);
        // Lost acknowledgements cannot cause the same input to execute twice.
        write_all(fd, request, sizeof(request));
        CHECK(read_all(fd, response, 17));
        CHECK(mgl_decode(response, 17, &packet) && packet.type == MGL_ERROR);
        close(fd); _exit(0);
    }
    MGLPair *pair = mgl_create(rom, sizeof(rom), saves[0], sizeof(saves[0]), saves[1], sizeof(saves[1]), boot, sizeof(boot)); CHECK(pair);
    int fd = accept(listener, NULL, NULL); CHECK(fd >= 0);
    uint8_t request[17], response[16 + MGL_PIXELS * 2], black[MGL_PIXELS * 2] = {0}; MGLPacket packet;
    double start = now();
    for (uint64_t frame = 0; frame < 4; frame++) {
        CHECK(read_all(fd, request, sizeof(request)) && mgl_decode(request, sizeof(request), &packet));
        CHECK(mgl_advance(pair, packet.sequence, 0, packet.payload[0]));
        CHECK(mgl_frames(pair) == frame + 1);
        CHECK(mgl_encode(response, sizeof(response), MGL_FRAME, mgl_frames(pair), black, sizeof(black)));
        write_all(fd, response, sizeof(response));
    }
    CHECK(now() - start >= .08);
    CHECK(!read_all(fd, request, sizeof(request))); close(fd);
    CHECK(mgl_frames(pair) == 4); // Partial request did not mutate the pair.
    mgl_set_connected(pair, 0);
    uint8_t before[MGL_SAVE_SIZE], after[MGL_SAVE_SIZE]; CHECK(mgl_battery(pair, 0, before));
    usleep(50000);
    CHECK(!mgl_advance(pair, 4, 0, 0)); CHECK(mgl_frames(pair) == 4);
    CHECK(mgl_battery(pair, 0, after) && !memcmp(before, after, sizeof(before)));
    fd = accept(listener, NULL, NULL); CHECK(fd >= 0); mgl_set_connected(pair, 1);
    CHECK(read_all(fd, request, sizeof(request)) && mgl_decode(request, sizeof(request), &packet));
    CHECK(mgl_advance(pair, packet.sequence, 0, packet.payload[0]) && mgl_frames(pair) == 5);
    CHECK(mgl_encode(response, sizeof(response), MGL_FRAME, 5, black, sizeof(black))); write_all(fd, response, sizeof(response));
    CHECK(read_all(fd, request, sizeof(request)) && mgl_decode(request, sizeof(request), &packet));
    CHECK(!mgl_advance(pair, packet.sequence, 0, packet.payload[0]) && mgl_frames(pair) == 5);
    uint8_t error = 1; CHECK(mgl_encode(response, sizeof(response), MGL_ERROR, 5, &error, 1)); write_all(fd, response, 17);
    close(fd); close(listener); int status; CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
    CHECK(!memcmp(before, saves[0], sizeof(before))); mgl_destroy(pair);
    puts("PASS: real loopback TCP, 20ms latency, fragmented requests, interrupted packet,");
    puts("      disconnect freeze, same-pair reconnect, duplicate rejection, save preservation");
    return 0;
}
