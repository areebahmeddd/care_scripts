#!/bin/bash

ES_VERSION="8.11.1"
SNOWSTORM_VERSION="10.7.0"
SNOWSTORM_JAR_URL="https://github.com/IHTSDO/snowstorm/releases/download/${SNOWSTORM_VERSION}/snowstorm-${SNOWSTORM_VERSION}.jar"
ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"
ES_HOME="./elasticsearch-${ES_VERSION}"
SNOWSTORM_JAR="./snowstorm-${SNOWSTORM_VERSION}.jar"

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

if [ ! -f "$SNOWSTORM_JAR" ]; then
    echo "Downloading Snowstorm $SNOWSTORM_VERSION..."
    curl -L -o $SNOWSTORM_JAR $SNOWSTORM_JAR_URL
else
    echo "Snowstorm already downloaded."
fi

echo "Starting Elasticsearch..."
$ES_HOME/bin/elasticsearch -d

echo "Waiting for Elasticsearch..."
until curl -s "http://localhost:9200/_cluster/health?wait_for_status=yellow" >/dev/null; do
    echo -n "."
    sleep 2
done
echo
echo "Elasticsearch is ready."

echo "Starting Snowstorm (read-only)..."
java -Xms2g -Xmx4g -jar $SNOWSTORM_JAR --snowstorm.rest-api.readonly=true
