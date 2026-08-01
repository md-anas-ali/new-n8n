# ---------------------------------------------------------------------------
# n8n + ffmpeg + edge-tts, sized for a strict 400MB RAM host.
# Base image pinned to the n8n 1.x line (still actively patched by n8n as of
# this writing) instead of :latest, which now tracks the newer 2.x line -
# 2.x runs Code-node execution in a separate task-runner process by default,
# which adds a second Node.js process's worth of baseline RAM, and its
# images are noticeably larger (~334-364MB compressed vs ~297MB for 1.x).
# All node typeVersions this workflow uses (httpRequest 4.2, googleSheets
# 4.5, if 2.2, set 3.4, code 2, splitInBatches 3) were already supported
# well before 1.123, so nothing in the workflow needs 2.x.
# ---------------------------------------------------------------------------
FROM n8nio/n8n:1.123.52

USER root

# ffmpeg              -> Make Clip / Concat + BGM + Subtitle / Extract QC Frames / Generate Thumbnail
# python3             -> Build Full SRT (subtitle timing script)
# py3-pip + edge-tts  -> TTS (Eleven->Edge->Silent) fallback voice
# curl                -> TTS node's direct ElevenLabs call
# coreutils           -> real `sort -V` (busybox's sort does not support -V reliably)
# gawk                -> the awk math used throughout Make Clip / Build Full SRT
# font-dejavu + fontconfig -> subtitle burn-in font ("FontName=DejaVu Sans")
# tzdata              -> correct $now.toISO() / YouTube publishAt scheduling
RUN apk add --no-cache \
        ffmpeg \
        python3 \
        py3-pip \
        curl \
        bash \
        coreutils \
        gawk \
        font-dejavu \
        fontconfig \
        tzdata \
    && pip3 install --no-cache-dir --break-system-packages edge-tts \
    && fc-cache -f \
    && rm -rf /var/cache/apk/* /root/.cache /tmp/*

USER node

# ---- RAM-safety defaults (matches the "RAM SAFETY (400MB HOST)" sticky note ----
# ---- inside the workflow itself) ----
# N8N_DEFAULT_BINARY_DATA_MODE=filesystem is the single biggest lever: without it,
# every image/audio/video buffer stays IN MEMORY as it passes between nodes.
ENV N8N_DEFAULT_BINARY_DATA_MODE=filesystem \
    NODE_OPTIONS="--max-old-space-size=170" \
    UV_THREADPOOL_SIZE=2 \
    EXECUTIONS_DATA_SAVE_ON_SUCCESS=none \
    EXECUTIONS_DATA_SAVE_ON_ERROR=none \
    EXECUTIONS_DATA_PRUNE=true \
    EXECUTIONS_DATA_MAX_AGE=24 \
    N8N_METRICS=false \
    N8N_DIAGNOSTICS_ENABLED=false \
    N8N_PUBLIC_API_DISABLED=true \
    GENERIC_TIMEZONE=Asia/Dhaka

EXPOSE 5678

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD wget -q --spider http://localhost:5678/healthz || exit 1
