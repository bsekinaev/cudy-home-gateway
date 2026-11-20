/* Disposable loopback resolver for live-procfs tests; never part of runtime. */
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr))) return 1;
    socklen_t size = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &size)) return 1;
    printf("%u\n", ntohs(addr.sin_port)); fflush(stdout);
    for (;;) {
        unsigned char packet[1024];
        struct sockaddr_in peer;
        socklen_t peer_size = sizeof(peer);
        ssize_t length = recvfrom(fd, packet, sizeof(packet)-16, 0,
                                  (struct sockaddr *)&peer, &peer_size);
        if (length < 12) continue;
        size_t end = 12;
        while (end < (size_t)length && packet[end] && packet[end] <= 63)
            end += packet[end] + 1;
        if (end + 5 > (size_t)length || packet[end] != 0) continue;
        end += 5;
        packet[2]=0x81; packet[3]=0x80;
        packet[4]=0; packet[5]=1; packet[6]=0; packet[7]=1;
        memset(packet+8, 0, 4);
        const unsigned char answer[16] = {
            0xc0,0x0c,0,1,0,1,0,0,0,30,0,4,192,0,2,7
        };
        memcpy(packet+end, answer, sizeof(answer));
        sendto(fd, packet, end+sizeof(answer), 0, (struct sockaddr *)&peer, peer_size);
    }
}
