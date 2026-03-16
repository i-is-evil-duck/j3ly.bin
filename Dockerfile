FROM alpine:latest AS builder
RUN apk add --no-cache curl tar xz upx && \
    curl -L https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz | tar xJ -C /opt && \
    ln -s /opt/zig-linux-x86_64-0.11.0 /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig
WORKDIR /app
COPY . .
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall && \
    upx --best /app/zig-out/bin/share

FROM scratch
COPY --from=builder /app/zig-out/bin/share /share
ENV DATA_DIR=/data
EXPOSE 8080
ENTRYPOINT ["/share"]
