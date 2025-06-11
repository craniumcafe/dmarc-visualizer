FROM grafana/grafana-oss:latest-ubuntu

# Install dashboard and dependencies

USER root

# Use your patched dashboard
COPY --chown=grafana:root dashboards/DMARC_Reports-1749660606764.json /var/lib/grafana/dashboards/DMARC_Reports-1749660606764.json

RUN grafana cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-piechart-panel
RUN grafana cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-worldmap-panel
RUN grafana cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-opensearch-datasource
RUN chown -R grafana:root /var/lib/grafana/plugins

# Copy provisioning files and fix permissions
COPY --chown=grafana:root provisioning/ /etc/grafana/provisioning/
RUN chmod -R +X /etc/grafana/provisioning

# Install AWS CLI
RUN apt-get update && \
    apt-get install -y awscli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install SSM agent 
RUN apt-get update && \
    apt-get install -y wget unzip && \
    wget https://s3.amazonaws.com/amazon-ssm-us-east-1/latest/debian_amd64/amazon-ssm-agent.deb && \
    dpkg -i amazon-ssm-agent.deb && \
    rm amazon-ssm-agent.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# install pip
RUN apt-get update && \
    apt-get install -y python3 python3-pip python3-dev build-essential libffi-dev libssl-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Upgrade pip (sometimes required for newer packages)
RUN pip3 install --upgrade pip setuptools wheel

# Install aws-requests-auth (from PyPI)
RUN pip3 install aws-requests-auth

# Install aws-es-curl (from GitHub)
RUN pip3 install awscurl

# Install jq (required for ECS Exec Checker)
RUN apt-get update && apt-get install -y jq && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Amazon ECS Exec Checker
RUN curl -Ls https://raw.githubusercontent.com/aws-containers/amazon-ecs-exec-checker/main/check-ecs-exec.sh -o /usr/local/bin/check-ecs-exec.sh \
    && chmod +x /usr/local/bin/check-ecs-exec.sh

USER grafana

# Configure Grafana
ENV GF_AUTH_ANONYMOUS_ENABLED=false
ENV GF_AWS_ALLOWED_AUTH_PROVIDERS=default
ENV GF_LOG_LEVEL=debug
ENV GF_SECURITY_ADMIN_USER=admin
ENV GF_SECURITY_ADMIN_PASSWORD=B1k3.kevlab

CMD ["grafana", "server"]
