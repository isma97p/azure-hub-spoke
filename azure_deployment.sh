#!/bin/bash

###### AUTOMATED AZURE DEPLOYMENT BASH SCRIPT (UNDER CONSTRUCTION) ######
#VARIABLES
rg=secure-web-application-rg
fwpol=fw-policy
myip=$(curl https://api.ipify.org)
ipv4bastion=10.0.3.10
ipv4webapp=10.0.2.10
ipv4apirest1=172.16.1.10
ipv4apirest2=172.16.1.20
ipv4lb=172.16.1.5
fwipv4=10.0.1.4


#### CREACION GRUPO DE RECURSOS -- WORKING
az group create --name $rg --location northeurope

#### CREACION DE VNETS -- WORKING
az network vnet create --resource-group $rg --name VNET-hub-web-app --address-prefixes 10.0.0.0/16    --subnet-name default --subnet-prefixes 10.0.0.0/24             # RED HUB WEB APP
az network vnet create --resource-group $rg --name VNET-spoke-1-internal-api --address-prefixes 172.16.0.0/16  --subnet-name default --subnet-prefixes 172.16.0.0/24  # RED SPOKE1 INTERNAL API
az network vnet create --resource-group $rg --name VNET-spoke-2-data-centers --address-prefixes 192.168.0.0/16 --subnet-name default --subnet-prefixes 192.168.0.0/24 # RED SPOKE2 DATA CENTERS

#### CREACION DE SUBNETS -- WORKING -- NEED ROUTING TABLES
az network vnet subnet create --resource-group $rg --vnet-name VNET-hub-web-app --name AzureFirewallSubnet                  --address-prefixes 10.0.1.0/26                                                    # SUBNET HUB AZURE FIREWALL # hub-subnet-firewall -> AzureFirewallSubnet ?? #
az network vnet subnet create --resource-group $rg --vnet-name VNET-hub-web-app --name hub-subnet-dmz-web-app               --address-prefixes 10.0.2.0/24                                                    # SUBNET HUB DMZ WEB APP
az network vnet subnet create --resource-group $rg --vnet-name VNET-hub-web-app --name hub-subnet-bastion                   --address-prefixes 10.0.3.0/24                                                    # SUBNET HUB BASTION HOST
az network vnet subnet create --resource-group $rg --vnet-name VNET-spoke-1-internal-api --name spoke-1-subnet-internal-api --address-prefixes 172.16.1.0/24  --network-security-group nsg-internal-api-rest  # SUBNET SPOKE1 API REST
az network vnet subnet create --resource-group $rg --vnet-name VNET-spoke-2-data-centers --name spoke-2-subnet-database     --address-prefixes 192.168.1.0/24                                                 # SUBNET SPOKE2 MYSQL

#### PEERING -- WORKING
az network vnet peering create --resource-group $rg --name Peer-HubSpoke1 --vnet-name VNET-hub-web-app --remote-vnet VNET-spoke-1-internal-api
az network vnet peering create --resource-group $rg --name Peer-Spoke1SHub --vnet-name VNET-spoke-1-internal-api --remote-vnet VNET-hub-web-app
az network vnet peering create --resource-group $rg --name Peer-HubSpoke2 --vnet-name VNET-hub-web-app --remote-vnet VNET-spoke-2-data-centers
az network vnet peering create --resource-group $rg --name Peer-Spoke2Hub --vnet-name VNET-spoke-2-data-centers --remote-vnet VNET-hub-web-app

#### CREACION DE FIREWALL -- WORKING
az network public-ip create --resource-group $rg --name fw-pip 																		                                                     # PUBLIC IP FIREWALL
pip=$(az network public-ip list --resource-group $rg | grep ipAddress | awk -F '"' '{print $4}')                                                       # GET PUBLIC IP
az network firewall policy create --resource-group $rg --name fw-policy --sku Standard 												                                         # FIREWALL POLICY
az network firewall create --resource-group $rg --name fw-hub --tier Standard --firewall-policy $fwpol --public-ip fw-pip --vnet-name VNET-hub-web-app # FIREWALL INSTANCE
### FIREWALL RULES COLLECTION GROUP -- WORKING
az network firewall policy rule-collection-group create --resource-group $rg --policy-name $fwpol --name DNATRuleCollectionGroup --priority 100
## COLLECTION NAT + DNAT RDP RULE -- WORKING -- CHECK PRIVATE IP
az network firewall policy rule-collection-group collection add-nat-collection \
--resource-group $rg \
--policy-name $fwpol \
--name Coll-DNAT \
--rcg-name DNATRuleCollectionGroup \
--collection-priority 100 \
--action DNAT \
--rule-name rdp \
--description "DNAT RDP FOR ADMIN USERS" \
--destination-addresses $pip \
--source-addresses $myip \
--translated-address $ipv4bastion \
--translated-port 3389 \
--destination-ports 3389 \
--ip-protocols TCP
## DNAT HTTP RULE -- WORKING -- CHECK PRIVATE IP
az network firewall policy rule-collection-group collection rule add \
--resource-group $rg \
--policy-name $fwpol \
--collection-name Coll-DNAT \
--rcg-name DNATRuleCollectionGroup \
--name http \
--rule-type NatRule \
--description "DNAT HTTP FOR CLIENT USERS" \
--destination-addresses $pip \
--source-addresses '*' \
--translated-address $ipv4webapp \
--translated-port 8080 \
--destination-ports 80 \
--ip-protocols TCP


##### VMS
#### REQUIREMENTS VMS
### ASGS -- WORKING - PENDING ASG FOR MYSQL
az network asg create --resource-group $rg --name asg-hub-bastion-host   # ASG BASTION HOST
az network asg create --resource-group $rg --name asg-hub-web-app-server # ASG WEB APP HOST
az network asg create --resource-group $rg --name asg-internal-api-rest  # ASG API REST
### NSGS -- WORKING - PENDING NSG FOR MYSQL
az network nsg create --resource-group $rg --name nsg-hub-bastion-host   # NSG BASTION HOST
az network nsg create --resource-group $rg --name nsg-hub-web-app-server # NSG WEB APP
az network nsg create --resource-group $rg --name nsg-internal-api-rest  # NSG API REST
### ---------- NSG RULES ---------- ###
## NSG RULE RDP BASTION HOST -- WORKING 
az network nsg rule create \
  --resource-group $rg \
  --nsg-name nsg-hub-bastion-host \
  --name AllowRDPFromMyIP \
  --priority 100 \
  --access Allow \
  --direction Inbound \
  --description "Allow RDP from My IP" \
  --protocol Tcp \
  --destination-asgs asg-hub-bastion-host \
  --source-address-prefixes $myip \
  --destination-port-ranges 3389 \
  --source-port-ranges '*'
## NSG RULE WEB APP SERVER 8080 FROM BASTION -- WORKING
az network nsg rule create \
  --resource-group $rg \
  --nsg-name nsg-hub-web-app-server \
  --name Allow8080FromBastion \
  --priority 100 \
  --access Allow \
  --direction Inbound \
  --description "Allow 8080 from Bastion Host" \
  --protocol Tcp \
  --destination-asgs asg-hub-web-app-server \
  --source-asgs asg-hub-bastion-host \
  --destination-port-ranges 8080 \
  --source-port-ranges '*'
## NSG RULE WEB APP SERVER 8080 FROM ANY -- WORKING
az network nsg rule create \
  --resource-group $rg \
  --nsg-name nsg-hub-web-app-server \
  --name Allow8080FromAny \
  --priority 200 \
  --access Allow \
  --direction Inbound \
  --description "Allow 8080 from Any" \
  --protocol Tcp \
  --destination-asgs asg-hub-web-app-server \
  --source-address-prefixes '*' \
  --destination-port-ranges 8080 \
  --source-port-ranges '*'
## NSG RULE WEB APP SERVER SSH FROM BASTION -- WORKING
az network nsg rule create \
  --resource-group $rg \
  --nsg-name nsg-hub-web-app-server \
  --name AllowSSHFromBastion \
  --priority 300 \
  --access Allow \
  --direction Inbound \
  --description "Allow SSH From Bastion Host" \
  --protocol Tcp \
  --destination-asgs asg-hub-web-app-server \
  --source-asgs asg-hub-bastion-host \
  --destination-port-ranges 22 \
  --source-port-ranges '*'
## NSG RULE API REST 3000 FROM BASTION -- WORKING -- THIS MACHINE ONLY ALLOW CONNECTIONS FROM LOAD BALANCER (NEED TO REVIEW THE RULE)
az network nsg rule create \
  --resource-group $rg \
  --nsg-name nsg-internal-api-rest \
  --name Allow3000FromBastion \
  --priority 100 \
  --access Allow \
  --direction Inbound \
  --description "Allow 3000 From Bastion Host" \
  --protocol Tcp \
  --destination-asgs asg-internal-api-rest \
  --source-asgs asg-hub-bastion-host \
  --destination-port-ranges 3000 \
  --source-port-ranges 80
## NSG RULE API REST 3000 FROM WEB APP -- WORKING -- THIS MACHINE ONLY ALLOW CONNECTIONS FROM LOAD BALANCER (NEED TO REVIEW THE RULE)
az network nsg rule create \
  --resource-group $rg \
  --nsg-name nsg-internal-api-rest \
  --name Allow3000FromWebAPP \
  --priority 200 \
  --access Allow \
  --direction Inbound \
  --description "Allow 3000 From Web APP" \
  --protocol Tcp \
  --destination-asgs asg-internal-api-rest \
  --source-asgs asg-hub-web-app-server \
  --destination-port-ranges 3000 \
  --source-port-ranges 80

### NICS -- WORKING
az network nic create --resource-group $rg --name nic-hub-bastion-host --vnet-name VNET-hub-web-app --subnet hub-subnet-bastion --network-security-group nsg-hub-bastion-host --application-security-groups asg-hub-bastion-host --private-ip-address $ipv4bastion            # NIC VM BASTION HOST
az network nic create --resource-group $rg --name nic-hub-web-app-server --vnet-name VNET-hub-web-app --subnet hub-subnet-dmz-web-app --network-security-group nsg-hub-web-app-server --application-security-groups asg-hub-web-app-server --private-ip-address $ipv4webapp   # NIC VM WEB APP
az network nic create --resource-group $rg --name nic-internal-api-rest-1 --vnet-name VNET-spoke-1-internal-api --subnet spoke-1-subnet-internal-api --application-security-groups asg-internal-api-rest --private-ip-address $ipv4apirest1                                   # NIC VM API REST1
az network nic create --resource-group $rg --name nic-internal-api-rest-2 --vnet-name VNET-spoke-1-internal-api --subnet spoke-1-subnet-internal-api --application-security-groups asg-internal-api-rest --private-ip-address $ipv4apirest2                                   # NIC VM API REST2

### VM BASTION HOST (When specifying an existing NIC, do not specify NSG, public IP, ASGs, VNet or subnet)
az vm create --resource-group $rg \
--name vm-hub-bastion-host \
--computer-name WS22Bastion \
--image MicrosoftWindowsServer:WindowsServer:2022-datacenter:20348.2762.241006 \
--admin-username upgrade \
--admin-password Upgradeabc123. \
--nics nic-hub-bastion-host \
--zone 2 \
--size Standard_B2s

### VM WEB APP SERVER (When specifying an existing NIC, do not specify NSG, public IP, ASGs, VNet or subnet)
az vm create --resource-group $rg \
--name vm-hub-web-app-server \
--image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
--admin-username upgrade \
--admin-password Upgradeabc123. \
--nics nic-hub-web-app-server \
--zone 2 \
--size Standard_B2s \
--ssh-key-values pub/web_app_server.pub

### VM API REST 1
az vm create --resource-group $rg \
--name vm-internal-api-rest-1 \
--image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
--admin-username upgrade \
--admin-password Upgradeabc123. \
--nics nic-internal-api-rest-1 \
--zone 2 \
--size Standard_DS1_v2

### VM API REST 2
az vm create --resource-group $rg \
--name vm-internal-api-rest-2 \
--image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
--admin-username upgrade \
--admin-password Upgradeabc123. \
--nics nic-internal-api-rest-2 \
--zone 2 \
--size Standard_DS1_v2

#### WORKING ON CODE FOR LB, DB, PRIVATE ENDPOINT, FIREWALL RULES FOR APT-UBUNTU, DOCKER AND MS SSL AND REVIEW NSG RULES IN DEPTH