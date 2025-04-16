#!/bin/bash

# Versions for Elasticsearch and Snowstorm
ES_VERSION="8.11.1"
SNOWSTORM_VERSION="10.7.0"

# URLs to download Snowstorm JAR and Elasticsearch
SNOWSTORM_JAR_URL="https://github.com/IHTSDO/snowstorm/releases/download/${SNOWSTORM_VERSION}/snowstorm-${SNOWSTORM_VERSION}.jar"
ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"

# Local paths for Elasticsearch and Snowstorm files
ES_HOME="./elasticsearch-${ES_VERSION}"
SNOWSTORM_JAR="./snowstorm-${SNOWSTORM_VERSION}.jar"

# SNOMED CT snapshot details
SNOMED_ZIP_NAME="SnomedCT_IPSRF2_PRODUCTION_20240131T120000Z.zip"
SNOMED_ZIP_URL="https://snowstorm-test-files.s3.eu-west-1.amazonaws.com/${SNOMED_ZIP_NAME}"
SNOMED_ZIP_PATH="./${SNOMED_ZIP_NAME}"

install_java() {
    echo "Checking Java..."
    if ! command -v java >/dev/null 2>&1; then
        echo "Java not found. Installing OpenJDK 17..."
        sudo apt update && sudo apt install -y openjdk-17-jdk
        if ! command -v java >/dev/null 2>&1; then
            echo "Java installation failed."
            exit 1
        fi
    else
        echo "Java is already installed."
    fi
}

setup_elasticsearch() {
    if [ ! -d "$ES_HOME" ]; then
        echo "Downloading Elasticsearch $ES_VERSION..."
        curl -L -O $ES_URL
        echo "Extracting..."
        tar -xzf elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz
        rm elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz

        echo "Configuring Elasticsearch..."
        sed -i 's/-Xms1g/-Xms4g/g' $ES_HOME/config/jvm.options
        sed -i 's/-Xmx1g/-Xmx4g/g' $ES_HOME/config/jvm.options
        echo "xpack.security.enabled: false" >> $ES_HOME/config/elasticsearch.yml
    else
        echo "Elasticsearch already set up."
    fi
}

download_snowstorm() {
    if [ ! -f "$SNOWSTORM_JAR" ]; then
        echo "Downloading Snowstorm $SNOWSTORM_VERSION..."
        curl -L -o $SNOWSTORM_JAR $SNOWSTORM_JAR_URL
    else
        echo "Snowstorm already downloaded."
    fi
}

download_snomed_ct() {
    if [ ! -f "$SNOMED_ZIP_PATH" ]; then
        echo "Downloading SNOMED CT IPS RF2 snapshot..."
        curl -L -o "$SNOMED_ZIP_PATH" "$SNOMED_ZIP_URL"
    else
        echo "SNOMED CT zip already downloaded."
    fi
}

start_elasticsearch() {
    echo "Starting Elasticsearch..."
    $ES_HOME/bin/elasticsearch -d

    echo "Waiting for Elasticsearch..."
    until curl -s "http://localhost:9200/_cluster/health?wait_for_status=yellow" >/dev/null; do
        echo -n "."
        sleep 2
    done
    echo
    echo "Elasticsearch is ready."
}

import_snomed_ct() {
    echo "Importing SNOMED CT snapshot..."
    java -Xms2g -Xmx4g -jar $SNOWSTORM_JAR --delete-indices --import="$SNOMED_ZIP_PATH" --exit
    echo "SNOMED CT import complete."
}

start_snowstorm() {
    echo "Starting Snowstorm in read-only mode..."
    java -Xms2g -Xmx4g -jar $SNOWSTORM_JAR --snowstorm.rest-api.readonly=true
}

# Main script execution

install_java
setup_elasticsearch
download_snowstorm
download_snomed_ct
start_elasticsearch
import_snomed_ct
start_snowstorm
