# EXPECT: K3-secret-in-arg
FROM alpine:3.19@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899
ARG AWS_SECRET_ACCESS_KEY
RUN echo "using build secret"
USER 1000
