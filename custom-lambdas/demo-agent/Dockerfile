# AI Gateway POC — Demo Agent container for AgentCore Runtime.
#
# AgentCore Runtime requires ARM64 images that listen on 0.0.0.0:8080 and
# expose POST /invocations + GET /ping. BedrockAgentCoreApp provides both.
FROM --platform=linux/arm64 python:3.12-slim
# nosemgrep: avoid-platform-with-from — linux/arm64 is required by AgentCore Runtime; cannot use buildx --platform here
# Using Docker Hub (python:3.12-slim) rather than public.ecr.aws mirror intentionally:
# Finch's buildkit runs in a separate Lima VM and does not inherit finch-login credentials,
# causing 403s against public.ecr.aws. Docker Hub public images need no authentication
# and work identically with both Docker and Finch.

WORKDIR /app

# System certs for outbound HTTPS (Cognito token endpoint, gateway MCP URL).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

# Run as non-root user for security. chown ensures the app files copied above
# are readable. No runtime file writes occur so /app read access is sufficient.
RUN useradd -m appuser && chown -R appuser /app
USER appuser

# Tell agent.py to start the HTTP server (instead of the interactive loop).
ENV AGENTCORE_RUNTIME=1
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

# AgentCore Runtime manages container lifecycle — no active health probe needed.
HEALTHCHECK NONE

CMD ["python", "agent.py"]
