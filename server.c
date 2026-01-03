#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>

#define MAX_CLIENTS 64
#define BUF_SIZE    8192

struct server {
	struct pollfd fds[MAX_CLIENTS];
	int nfds;
	int host_fd;
};

static void remove_client(struct server *srv, int client_id)
{
	int fd = srv->fds[client_id].fd;
	printf("Client on socket %d disconnected\n", fd);

	int is_host = (fd == srv->host_fd);

	if (srv->host_fd != -1 && !is_host) {
		char msg[64];
		int len = snprintf(msg, sizeof(msg), "0:DISCONNECT:%d\n", fd);
		send(srv->host_fd, msg, len, 0);
	}

	close(fd);

	if (is_host)
		srv->host_fd = -1;

	/* Move last element to current position to fill gap */
	srv->fds[client_id] = srv->fds[srv->nfds - 1];
	srv->nfds--;
}

static void accept_connection(int server_fd, struct server *srv)
{
	int new_fd = accept(server_fd, NULL, NULL);
	if (new_fd < 0) {
		fprintf(stderr, "Accept failed\n");
		return;
	}

	if (srv->nfds >= MAX_CLIENTS) {
		fprintf(stderr, "Too many clients\n");
		close(new_fd);
		return;
	}

	int opt = 1;
	setsockopt(new_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

	srv->fds[srv->nfds].fd = new_fd;
	srv->fds[srv->nfds].events = POLLIN;

	int is_host = (srv->host_fd < 0);
	if (is_host)
		srv->host_fd = new_fd;
	else {
		char msg[64];
		int len = snprintf(msg, sizeof(msg), "0:CONNECT:%d\n", new_fd);
		send(srv->host_fd, msg, len, 0);
	}

	printf("New connection: %d%s\n", new_fd, is_host ? " (host)" : "");
	srv->nfds++;
}

static int handle_client_data(struct server *srv, int client_id)
{
	char buf[BUF_SIZE];
	ssize_t n = recv(srv->fds[client_id].fd, buf, sizeof(buf) - 1, 0);

	if (n <= 0) {
		remove_client(srv, client_id);
		return -1;
	}

	buf[n] = '\0';
	int client_fd = srv->fds[client_id].fd;

	if (client_fd == srv->host_fd) {
		/* Host sending to client: "TARGET_FD:DATA" */
		char *sep = strchr(buf, ':');
		if (sep) {
			*sep = '\0';
			int target_fd = atoi(buf);
			char *data = sep + 1;
			size_t data_len = n - (sep - buf) - 1;

			for (int i = 0; i < srv->nfds; ++i) {
				if (srv->fds[i].fd == target_fd) {
					send(target_fd, data, data_len, 0);
					break;
				}
			}
		}
	} else if (srv->host_fd != -1) {
		/* Client sending to host: "DATA" -> "CLIENT_FD:DATA" */
		char fwd_buf[BUF_SIZE + 32];
		int prefix_len =
			snprintf(fwd_buf, sizeof(fwd_buf), "%d:", client_fd);
		if (prefix_len > 0 &&
		    (size_t)prefix_len + n < sizeof(fwd_buf)) {
			memcpy(fwd_buf + prefix_len, buf, n);
			send(srv->host_fd, fwd_buf, prefix_len + n, 0);
		}
	}

	return 0;
}

int main()
{
	int server_fd = socket(AF_INET, SOCK_STREAM, 0);
	if (server_fd < 0) {
		fprintf(stderr, "Socket creation failed\n");
		return 1;
	}

	int opt = 1;
	setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
	setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

	struct sockaddr_in addr = { .sin_family = AF_INET,
				    .sin_port = htons(8080),
				    .sin_addr.s_addr = INADDR_ANY };

	if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		fprintf(stderr, "Bind failed\n");
		return 1;
	}

	if (listen(server_fd, MAX_CLIENTS) < 0) {
		fprintf(stderr, "Listen failed\n");
		return 1;
	}

	printf("Listening...\n");

	struct server srv = { .nfds = 1, .host_fd = -1 };
	srv.fds[0].fd = server_fd;
	srv.fds[0].events = POLLIN;

	while (poll(srv.fds, (nfds_t)srv.nfds, -1) >= 0) {
		for (int i = 0; i < srv.nfds; ++i) {
			if (srv.fds[i].revents &
			    (POLLERR | POLLHUP | POLLNVAL)) {
				remove_client(&srv, i);
				i--;
				continue;
			}

			if (srv.fds[i].revents & POLLIN) {
				if (srv.fds[i].fd == server_fd)
					accept_connection(server_fd, &srv);
				else if (handle_client_data(&srv, i) < 0)
					i--;
			}
		}
	}

	close(server_fd);
	return 0;
}
