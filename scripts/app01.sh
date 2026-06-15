#!/bin/bash

# update system files

sudo dnf update -y
# install java
sudo dnf -y install java-17-openjdk java-17-openjdk-devel

#  install git and wget
sudo dnf install git wget tee -y

# go to temp dir

cd /tmp/

# Download & Tomcat Package
sudo wget https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.26/bin/apache-tomcat-10.1.26.tar.gz

# extract the tar file
tar xzvf apache-tomcat-10.1.26.tar.gz
#Add tomcat user
sudo useradd --home-dir /usr/local/tomcat --shell /sbin/nologin tomcat
# chown -R tomcat.tomcat /usr/local/tomcat and Make tomcat user owner of tomcat home dir
sudo cp -r /tmp/apache-tomcat-10.1.26/* /usr/local/tomcat/
chown -R tomcat.tomcat /usr/local/tomcat

# update user data in tomcat service

sudo tee /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Tomcat
After=network.target

[Service]
User=tomcat
Group=tomcat
WorkingDirectory=/usr/local/tomcat
Environment=JAVA_HOME=/usr/lib/jvm/jre
Environment=CATALINA_PID=/var/tomcat/%i/run/tomcat.pid
Environment=CATALINA_HOME=/usr/local/tomcat
Environment=CATALINE_BASE=/usr/local/tomcat
ExecStart=/usr/local/tomcat/bin/catalina.sh run
ExecStop=/usr/local/tomcat/bin/shutdown.sh
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now tomcat
