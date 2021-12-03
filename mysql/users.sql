-- Designate
CREATE USER 'designate'@'%' IDENTIFIED BY 'designate';
CREATE DATABASE designate CHARACTER SET = 'UTF8';
GRANT ALL PRIVILEGES ON designate.* TO 'designate'@'%';

-- Keystone
CREATE USER 'keystone'@'%' IDENTIFIED BY 'keystone';
CREATE DATABASE keystone CHARACTER SET = 'UTF8';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%';

-- Keycloak
CREATE USER 'keycloak'@'%' IDENTIFIED BY 'keycloak';
CREATE DATABASE keycloak CHARACTER SET = 'UTF8';
GRANT ALL PRIVILEGES ON keycloak.* TO 'keycloak'@'%';

FLUSH PRIVILEGES;