# An instance of the local environment: Amazon Linux 2023 with systemd as PID 1, and nothing more.
# What an EC2 instance runs (Java, WildFly, the CodeDeploy agent, Ansible, the systemd unit) is
# installed afterwards by remote/install-wildfly.sh, as in AWS.
FROM amazonlinux:2023.12.20260918.0

RUN dnf install -y --quiet systemd procps-ng shadow-utils findutils hostname which util-linux \
  && dnf clean all

STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
