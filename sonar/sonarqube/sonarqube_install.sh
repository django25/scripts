#!/bin/bash

SONAR_VERSION=https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-25.2.0.102705.zip
PLUGIN_VERSION=https://github.com/mc1arke/sonarqube-community-branch-plugin/releases/download/1.23.0/sonarqube-community-branch-plugin-1.23.0.jar
PLUGIN_VERSION_NUM=1.23.0
DB_USER= {DB_USER}
DB_PASS= {DB_PASS}
DB_NAME= {DB_NAME}

# Actualizar el sistema
echo "Actualizando el sistema..."
sudo apt update && sudo apt upgrade -y

# Instalar dependencias necesarias
echo "Instalando dependencias..."
sudo apt install -y openjdk-17-jdk unzip wget
java -version

# Instalacion Postgresql
# Agregar repositorio de PostgreSQL
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ `lsb_release -cs`-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -

# Instalar PostgreSQL
sudo apt update
sudo apt install postgresql postgresql-contrib -y

# Habilitar y arrancar PostgreSQL
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Verificar si PostgreSQL está corriendo
if systemctl is-active --quiet postgresql; then
    echo "✅ PostgreSQL está corriendo."
else
    echo "❌ ERROR: PostgreSQL no se inició correctamente."
    exit 1  
fi

# Mostrar el estado y la versión de PostgreSQL
sudo systemctl status postgresql --no-pager
psql --version

#Creacion del usuario de sonarqube para trabajo con sonar
sudo -u postgres createuser $DB_USER

# Conectarse a postgresql para la creacion del usuario y la tabla
sudo -u postgres psql <<EOF
ALTER USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';
CREATE DATABASE $DB_NAME WITH OWNER $DB_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

#Descargar SonarQube
echo "Descargando SonarQube..."
cd /opt
sudo wget $SONAR_VERSION

#Descomprimir SonarQube
echo "Descomprimiendo SonarQube..."
sudo unzip sonarqube-*.zip
sudo mv $(ls -d sonarqube-*/ | head -n 1) sonarqube

#Descargar Pluigin
echo "Descargando SonarQube Plugin Branch..."
cd /opt/sonarqube/extensions/plugins
sudo wget $PLUGIN_VERSION


# Crear un usuario para SonarQube
echo "Creando usuario sonarqube..."
sudo groupadd sonarqube
sudo useradd -d /opt/sonarqube -g sonarqube sonarqube
sudo chown sonarqube:sonarqube /opt/sonarqube -R

CONFIG_FILE_SONAR="/opt/sonarqube/conf/sonar.properties"

# Definir las líneas que queremos agregar
CONFIG_LINES=(
    "sonar.jdbc.username=$DB_USER"
    "sonar.jdbc.password=$DB_PASS"
    "sonar.jdbc.url=jdbc:postgresql://localhost:5432/$DB_NAME"
    "sonar.ce.javaAdditionalOpts=-javaagent:./extensions/plugins/sonarqube-community-branch-plugin-$PLUGIN_VERSION_NUM.jar=ce"
    "sonar.web.javaAdditionalOpts=-javaagent:./extensions/plugins/sonarqube-community-branch-plugin-$PLUGIN_VERSION_NUM.jar=web"
)

# Recorrer cada línea y verificar si ya existe antes de agregarla
for LINE in "${CONFIG_LINES[@]}"; do
    if ! grep -qF "$LINE" "$CONFIG_FILE_SONAR"; then
        echo "$LINE" >> "$CONFIG_FILE_SONAR"
    fi
done

# Validar si la línea ya existe en el archivo
if ! grep -Fxq "RUN_AS_USER=sonarqube" /opt/sonarqube/bin/linux-x86-64/sonar.sh
then
    # Si no existe, agregar la línea en la segunda fila
    sed -i '2i RUN_AS_USER=sonarqube' /opt/sonarqube/bin/linux-x86-64/sonar.sh
    echo "Se agrega usuario al sonar.sh"
else
    echo "El Usuario ya existe en el archivo"
fi

# Configurar el servicio de SonarQube

FILE="/etc/systemd/system/sonar.service"
# Si el archivo existe, eliminarlo
if [ -f "$FILE" ]; then
    echo "Eliminando archivo existente: $FILE"
    sudo rm "$FILE"
fi
# Crear un nuevo archivo con el contenido deseado
echo "Creando nuevo archivo: $FILE"
sudo tee "$FILE" > /dev/null <<EOF
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonarqube
Group=sonarqube
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

#Configurar recursos del sistema para la tarea de Sonarqube

CONFIG_FILE="/etc/sysctl.conf"
# Definir las líneas que queremos agregar
CONFIG_LINES=(
        "vm.max_map_count=262144"
        "fs.file-max=65536"
        "ulimit -n 65536"
        "ulimit -u 4096"
)
# Recorrer cada línea y verificar si ya existe antes de agregarla
for LINE in "${CONFIG_LINES[@]}"; do
    if ! grep -qF "$LINE" "$CONFIG_FILE"; then
        echo "$LINE" >> "$CONFIG_FILE"
    fi
done

#Recargar systemd para aplicar cambios
sudo systemctl daemon-reload
#Habilitar el servicio para que inicie automáticamente
sudo systemctl enable sonar.service
#Iniciar el servicio
sudo systemctl start sonar.service
#Verificar el estado del servicio
sudo systemctl status sonar.service

# Configurar el firewall (si está habilitado)
echo "Configurando el firewall..."
sudo ufw allow 9000/tcp
sudo ufw reload

# Mostrar mensaje de finalización
echo "Instalación de SonarQube completada."


