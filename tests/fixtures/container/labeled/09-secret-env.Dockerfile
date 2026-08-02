# EXPECT: K3-secret-in-env
FROM alpine:3.19@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899
ENV DATABASE_PASSWORD=hunter2placeholder
USER 1000
CMD ["/bin/app"]
