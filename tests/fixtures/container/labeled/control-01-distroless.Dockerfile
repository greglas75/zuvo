# EXPECT: none
FROM gcr.io/distroless/static-debian12:nonroot@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899
COPY --chmod=0755 app /app
CMD ["/app"]
