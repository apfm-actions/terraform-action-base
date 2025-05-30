FROM alpine:3.12.7

WORKDIR /app

ENV CRYPTOGRAPHY_DONT_BUILD_RUST=1

# Prep base system
RUN set -e \
	&& ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime \
	&& apk --update add --no-cache --virtual .build-deps \
	&& apk add --no-cache \
		build-base \
		python3-dev \
		libffi-dev \
		openssl-dev \
		git \
		jq \
		curl \
		libffi \
		openssl \
		rust \
	&& python3 -m ensurepip --upgrade \
	&& python3 -m pip install --upgrade pip \
	&& python3 -m pip install --upgrade \
		awscli==1.18.49 \
		s3cmd==2.1.0 \
		credstash==1.17.1 \
	&& apk --purge -v del \
		build-base \
		python3-dev \
		libffi-dev \
		openssl-dev \
		rust \
	&& rm -f /var/cache/apk/*

# Install Terraform
COPY *-install /app/
RUN set -e \
	&& ./terraform-install '0.12.31' \
	&& ./credstash-install '0.4.1'

# Manage the Entrypoint
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
