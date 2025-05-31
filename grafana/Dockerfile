FROM grafana/grafana-oss:latest-ubuntu

# Install dashboard and dependencies
ARG DMARC_DASHBOARD=https://raw.githubusercontent.com/domainaware/parsedmarc/master/grafana/Grafana-DMARC_Reports.json
ADD --chown=grafana:root ${DMARC_DASHBOARD} /var/lib/grafana/dashboards/
RUN grafana-cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-piechart-panel
RUN grafana-cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-worldmap-panel

# Copy provisioning files and fix permissions
COPY --chown=grafana:root provisioning/ /etc/grafana/provisioning/
COPY --chown=grafana:root provisioning/datasources/datasource.yaml /etc/grafana/provisioning/datasources/datasource.yaml

USER root
RUN chmod -R +X /etc/grafana/provisioning

# Install SSM agent (Alpine version)
RUN apt-get update && \
    apt-get install -y wget unzip && \
    wget https://s3.amazonaws.com/amazon-ssm-us-east-1/latest/debian_amd64/amazon-ssm-agent.deb && \
    dpkg -i amazon-ssm-agent.deb && \
    rm amazon-ssm-agent.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

USER grafana

# Configure Grafana
ENV GF_AUTH_ANONYMOUS_ENABLED=false
