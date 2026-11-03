# Base pinned by index digest in one literal FROM so Dependabot can bump it; scripts/image/build.sh can swap the registry with a named build context (ADR 0007 S21).
FROM public.ecr.aws/docker/library/python:3.13-slim@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962 AS base

# Lambda Web Adapter v1.1.0, pinned by index digest (ADR 0012 L1). A named stage (not FROM base) so Dependabot reads
# the tag; on Lambda it runs as an extension and forwards events to AWS_LWA_PORT, elsewhere it is inert.
FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0@sha256:17cfd08eff1dfea3f6a9a1e9c65fdac80aa4919b6085e746615530f43f57d2f1 AS lambda-adapter

FROM base AS test
WORKDIR /app
COPY src ./src
COPY tests ./tests
RUN python -m unittest discover -s tests

FROM base AS runtime
ARG GIT_SHA=local
LABEL org.opencontainers.image.revision=${GIT_SHA} \
      org.opencontainers.image.source=https://github.com/trungleviet-agilityio/ship-it-serverless
ENV GIT_SHA=${GIT_SHA} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    AWS_LWA_PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/health
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
# The app is stdlib only: remove pip and setuptools (and the libraries they vendor) from the runtime image.
RUN python -m pip uninstall --yes pip setuptools wheel
WORKDIR /app
# Copy from the test stage so the final image is only built if tests passed.
COPY --from=test --chown=app:app /app/src ./src
COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"]
CMD ["python", "src/board.py"]
