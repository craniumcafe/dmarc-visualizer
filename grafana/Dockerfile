FROM grafana/grafana-oss:latest-ubuntu

# Install dashboard and dependencies
# ARG DMARC_DASHBOARD=https://raw.githubusercontent.com/domainaware/parsedmarc/master/grafana/Grafana-DMARC_Reports.json
# ADD --chown=grafana:root ${DMARC_DASHBOARD} /var/lib/grafana/dashboards/

USER root

# Use your patched dashboard
COPY --chown=grafana:root dashboards/DMARC_Reports.json /var/lib/grafana/dashboards/DMARC_Reports.json
RUN grafana-cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-piechart-panel
RUN grafana-cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-worldmap-panel

# Copy provisioning files and fix permissions
COPY --chown=grafana:root provisioning/ /etc/grafana/provisioning/
COPY --chown=grafana:root provisioning/datasources/datasource.yaml /etc/grafana/provisioning/datasources/datasource.yaml
COPY --chown=grafana:root start-grafana.sh /start-grafana.sh
RUN chmod +x /start-grafana.sh
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

USER grafana

# Configure Grafana
ENV GF_AUTH_ANONYMOUS_ENABLED=false

ENTRYPOINT ["/start-grafana.sh"]
