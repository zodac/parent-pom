FROM maven:3.9.16-eclipse-temurin-26

RUN apt-get update && \
    apt-get install -yqq --no-install-recommends \
    git \
    gnupg \
    jq \
    openssh-client \
    shfmt \
    vim \
    && \
    apt-get autoremove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*    

COPY ./.devcontainer/config/.bashrc /root/.bashrc
COPY ./.devcontainer/config/.bash_completion /root/.bash_completion
