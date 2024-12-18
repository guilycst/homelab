#!/bin/bash

set -e  # Interrompe o script em caso de erro

# Variáveis
DOCKER_VERSION="0.3.16"
ARCH="amd64"
CRI_DOCKERD_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v${DOCKER_VERSION}/cri-dockerd-${DOCKER_VERSION}.${ARCH}.tgz"
INSTALL_DIR="/usr/local/bin"
TMP_DIR="/tmp/docker-cri-dockerd-install"

echo "==> Removendo pacotes conflitantes..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -y $pkg || echo "Pacote $pkg não encontrado, continuando..."
done

echo "==> Atualizando os repositórios de pacotes..."
sudo apt-get update -y

echo "==> Instalando dependências necessárias..."
sudo apt-get install -y ca-certificates curl gnupg git

echo "==> Configurando o diretório de chaves para o Docker..."
sudo install -m 0755 -d /etc/apt/keyrings

echo "==> Baixando a chave GPG do Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Adicionando o repositório do Docker..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> Atualizando os repositórios para incluir o Docker..."
sudo apt-get update -y

echo "==> Instalando o Docker e seus componentes..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Testando a instalação do Docker..."
sudo docker run hello-world || { echo "Erro ao executar o Docker. Verifique a instalação."; exit 1; }

echo "==> Configurando o Docker para iniciar automaticamente..."
sudo systemctl enable docker
sudo systemctl start docker

echo "==> Configurando permissões de grupo para o Docker..."
sudo groupadd -f docker
sudo usermod -aG docker $USER

echo "==> Recarregue sua sessão para aplicar as permissões de grupo. Ou execute manualmente 'newgrp docker' para aplicar imediatamente."

echo "==> Instalando cri-dockerd..."
mkdir -p ${TMP_DIR}

echo "==> Baixando cri-dockerd versão ${DOCKER_VERSION}..."
curl -L ${CRI_DOCKERD_URL} -o ${TMP_DIR}/cri-dockerd.tgz

echo "==> Extraindo cri-dockerd..."
tar -xvf ${TMP_DIR}/cri-dockerd.tgz -C ${TMP_DIR}

echo "==> Instalando cri-dockerd em ${INSTALL_DIR}..."
sudo install -o root -g root -m 0755 ${TMP_DIR}/cri-dockerd/cri-dockerd ${INSTALL_DIR}/cri-dockerd

echo "==> Baixando arquivos de configuração do systemd para cri-dockerd..."
git clone https://github.com/Mirantis/cri-dockerd.git ${TMP_DIR}/cri-dockerd-repo

echo "==> Instalando arquivos de configuração do systemd..."
sudo install -d /etc/systemd/system
sudo install -m 644 ${TMP_DIR}/cri-dockerd-repo/packaging/systemd/* /etc/systemd/system

echo "==> Atualizando o caminho do binário no arquivo cri-docker.service..."
sudo sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service

echo "==> Recarregando daemon systemd e iniciando o serviço cri-dockerd..."
sudo systemctl daemon-reload
sudo systemctl enable --now cri-docker.service

echo "==> Limpando arquivos temporários..."
rm -rf ${TMP_DIR}

echo "==> Verificando o status do serviço cri-dockerd..."
sudo systemctl status cri-docker.service || { echo "O serviço cri-dockerd não foi iniciado corretamente."; exit 1; }

echo "==> Docker e cri-dockerd instalados e configurados com sucesso!"

