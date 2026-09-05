FROM perl:5.40-slim
WORKDIR /app
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq-dev gcc libc6-dev make ca-certificates \
 && cpanm --notest Dancer2 Plack HTTP::Message HTTP::Tiny DBI DBD::Pg JSON URI JSON::MaybeXS \
 && apt-get purge -y gcc libc6-dev make \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* /root/.cpanm
COPY app.psgi cpanfile ./
COPY lib ./lib
ENV PORT=8080
EXPOSE 8080
COPY bin ./bin
CMD ["perl", "bin/server"]
