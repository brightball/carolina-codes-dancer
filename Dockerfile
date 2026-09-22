FROM perl:5.40-slim
WORKDIR /app
COPY cpanfile ./
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq-dev gcc libc6-dev make ca-certificates \
 && cpanm --notest --installdeps . \
 && apt-get purge -y gcc libc6-dev make \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* /root/.cpanm
COPY app.psgi ./
COPY lib ./lib
COPY bin ./bin
ENV PORT=8080
EXPOSE 8080
CMD ["perl", "bin/server"]
