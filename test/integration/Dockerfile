# One image plays both roles: the "Pi" (sshd + rsync) and the "runner" that
# executes scripts/deploy.sh. Sharing an image means both sides already know
# the test client key and the server's host key.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server openssh-client rsync \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash deploy \
 && mkdir -p /run/sshd /srv/deploy /etc/test \
 && chown deploy:deploy /srv/deploy \
 && ssh-keygen -A \
 && ssh-keygen -q -t ed25519 -N "" -f /etc/test/client_key \
 && install -d -m 700 -o deploy -g deploy /home/deploy/.ssh \
 && install -m 600 -o deploy -g deploy /etc/test/client_key.pub /home/deploy/.ssh/authorized_keys \
 && printf 'PasswordAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/test.conf

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
