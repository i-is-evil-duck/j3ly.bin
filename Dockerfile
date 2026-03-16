FROM alpine:latest AS builder
RUN apk add --no-cache curl tar xz && \
    curl -L https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz | tar xJ -C /opt && \
    ln -s /opt/zig-linux-x86_64-0.11.0 /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig
WORKDIR /app
COPY . .
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall

FROM scratch
COPY --from=builder /app/zig-out/bin/share /share
COPY --from=builder /app/index.html /index.html
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV DATA_DIR=/data
EXPOSE 8080
ENTRYPOINT ["/share"]
