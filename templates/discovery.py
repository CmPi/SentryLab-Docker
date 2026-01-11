#!/usr/bin/env python3
"""
@file discovery.py
@repo https://github.com/CmPi/SentryLab-Docker
@brief Docker Container Discovery Script for Home Assistant
@date 2026-01-11
@version 0.1.11

Publishes MQTT discovery configs for Home Assistant auto-discovery
"""

import os
import json
import logging
from datetime import datetime

try:
    import docker
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: Required packages not installed")
    print("Run: pip install docker paho-mqtt")
    exit(1)

# Read SentryLab-Docker version
SENTRYLAB_VERSION = os.getenv("SENTRYLAB_VERSION", "unknown")
if SENTRYLAB_VERSION == "unknown":
    try:
        with open("/app/VERSION", "r") as f:
            SENTRYLAB_VERSION = f.read().strip()
    except:
        SENTRYLAB_VERSION = "unknown"

# Configuration from environment variables (aligned with SentryLab-PVE)
BROKER = os.getenv("BROKER", "localhost")
PORT = int(os.getenv("PORT", "1883"))
USER = os.getenv("USER", "")
PASS = os.getenv("PASS", "")
HA_BASE_TOPIC = os.getenv("HA_BASE_TOPIC", "homeassistant")
DEVICE_NAME = os.getenv("DEVICE_NAME", "Docker Host")
DEVICE_ID = os.getenv("DEVICE_ID", "docker_host")
PROXMOX_HOST = os.getenv("PROXMOX_HOST", "proxmox")
PROXMOX_VMID = os.getenv("PROXMOX_VMID", "0")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
DEBUG = os.getenv("DEBUG", "false").lower() == "true"

# Setup logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def on_connect(client, userdata, flags, rc):
    """MQTT connection callback"""
    if rc == 0:
        logger.info(f"Connected to MQTT broker at {BROKER}:{PORT}")
    else:
        logger.error(f"Failed to connect to MQTT broker. Return code: {rc}")


def setup_mqtt():
    """Initialize and connect to MQTT broker"""
    client = mqtt.Client()
    client.on_connect = on_connect
    
    if USER and PASS:
        client.username_pw_set(USER, PASS)
    
    if DEBUG:
        logger.info("DEBUG mode: MQTT publishing disabled")
        return None
    
    try:
        client.connect(BROKER, PORT, 60)
        client.loop_start()
        return client
    except Exception as e:
        logger.error(f"Failed to connect to MQTT broker: {e}")
        raise


def create_device_info():
    """Create device information for Home Assistant"""
    return {
        "identifiers": [DEVICE_ID],
        "name": DEVICE_NAME,
        "model": "Docker Engine",
        "manufacturer": "Docker Inc.",
        "sw_version": f"SentryLab-Docker v{SENTRYLAB_VERSION}"
    }


def publish_container_discovery(mqtt_client, container):
    """Publish Home Assistant discovery config for a container"""
    if mqtt_client is None and DEBUG:
        logger.debug(f"DEBUG: Would publish discovery for {container.name}")
        return
    
    container_name = container.name
    safe_name = container_name.replace("-", "_").replace(".", "_")
    device_info = create_device_info()
    
    # Topic prefix following hierarchy: sl_docker_<proxmox_host>_<vmid>_<container_name>
    topic_prefix = f"sl_docker_{PROXMOX_HOST}_{PROXMOX_VMID}_{safe_name}"
    
    # Get container image info
    try:
        image_full = container.image.tags[0] if container.image.tags else container.attrs["Config"]["Image"]
        # Parse image:tag format
        if ":" in image_full:
            image_name, image_tag = image_full.rsplit(":", 1)
        else:
            image_name = image_full
            image_tag = "latest"
    except:
        image_name = container.attrs["Config"]["Image"]
        image_tag = "unknown"
    
    # Binary Sensor - Running Status
    binary_sensor_config = {
        "name": f"{container_name} Status",
        "unique_id": f"{topic_prefix}_status",
        "state_topic": f"docker/{DEVICE_ID}/{container_name}/state",
        "value_template": "{{ value_json.running }}",
        "payload_on": "true",
        "payload_off": "false",
        "device_class": "running",
        "device": device_info,
        "icon": "mdi:docker"
    }
    
    topic = f"{HA_BASE_TOPIC}/binary_sensor/{topic_prefix}_status/config"
    mqtt_client.publish(topic, json.dumps(binary_sensor_config), retain=True)
    logger.info(f"Published discovery for {container_name} status")
    
    # Sensor - State
    state_sensor_config = {
        "name": f"{container_name} State",
        "unique_id": f"{topic_prefix}_state",
        "state_topic": f"docker/{DEVICE_ID}/{container_name}/state",
        "value_template": "{{ value_json.state }}",
        "device": device_info,
        "icon": "mdi:information-outline"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/{topic_prefix}_state/config"
    mqtt_client.publish(topic, json.dumps(state_sensor_config), retain=True)
    
    # Sensor - Uptime
    uptime_sensor_config = {
        "name": f"{container_name} Uptime",
        "unique_id": f"{topic_prefix}_uptime",
        "state_topic": f"docker/{DEVICE_ID}/{container_name}/state",
        "value_template": "{{ value_json.uptime }}",
        "device": device_info,
        "icon": "mdi:clock-outline"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/{topic_prefix}_uptime/config"
    mqtt_client.publish(topic, json.dumps(uptime_sensor_config), retain=True)
    
    # Sensor - Health
    health_sensor_config = {
        "name": f"{container_name} Health",
        "unique_id": f"{topic_prefix}_health",
        "state_topic": f"docker/{DEVICE_ID}/{container_name}/state",
        "value_template": "{{ value_json.health | default('N/A') }}",
        "device": device_info,
        "icon": "mdi:heart-pulse"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/{topic_prefix}_health/config"
    mqtt_client.publish(topic, json.dumps(health_sensor_config), retain=True)
    
    # Sensor - Image
    image_sensor_config = {
        "name": f"{container_name} Image",
        "unique_id": f"{topic_prefix}_image",
        "state_topic": f"docker/{DEVICE_ID}/{container_name}/state",
        "value_template": "{{ value_json.image }}",
        "device": device_info,
        "icon": "mdi:package-variant"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/{topic_prefix}_image/config"
    mqtt_client.publish(topic, json.dumps(image_sensor_config), retain=True)
    
    # Sensor - Image Version (new!)
    image_version_config = {
        "name": f"{container_name} Version",
        "unique_id": f"docker_{safe_name}_version",
        "state_topic": f"docker/{DEVICE_ID}/{container_name}/state",
        "value_template": "{{ value_json.image_version }}",
        "device": device_info,
        "icon": "mdi:tag"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/docker_{safe_name}/version/config"
    mqtt_client.publish(topic, json.dumps(image_version_config), retain=True)
    
    # Sensor - SentryLab Version
    sentrylab_version_config = {
        "name": f"{DEVICE_NAME} SentryLab Version",
        "unique_id": f"docker_{DEVICE_ID}_sentrylab_version",
        "state_topic": f"docker/{DEVICE_ID}/summary",
        "value_template": "{{ value_json.sentrylab_version }}",
        "device": device_info,
        "icon": "mdi:information"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/docker_{DEVICE_ID}/sentrylab_version/config"
    mqtt_client.publish(topic, json.dumps(sentrylab_version_config), retain=True)


def publish_summary_discovery(mqtt_client):
    """Publish Home Assistant discovery config for summary sensors"""
    if mqtt_client is None and DEBUG:
        logger.debug("DEBUG: Would publish summary discovery")
        return
    
    device_info = create_device_info()
    
    # Total containers
    total_config = {
        "name": f"{DEVICE_NAME} Total Containers",
        "unique_id": f"docker_{DEVICE_ID}_total",
        "state_topic": f"docker/{DEVICE_ID}/summary",
        "value_template": "{{ value_json.total }}",
        "device": device_info,
        "icon": "mdi:counter"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/docker_{DEVICE_ID}/total/config"
    mqtt_client.publish(topic, json.dumps(total_config), retain=True)
    
    # Running containers
    running_config = {
        "name": f"{DEVICE_NAME} Running Containers",
        "unique_id": f"docker_{DEVICE_ID}_running",
        "state_topic": f"docker/{DEVICE_ID}/summary",
        "value_template": "{{ value_json.running }}",
        "device": device_info,
        "icon": "mdi:play-circle"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/docker_{DEVICE_ID}/running/config"
    mqtt_client.publish(topic, json.dumps(running_config), retain=True)
    
    # Stopped containers
    stopped_config = {
        "name": f"{DEVICE_NAME} Stopped Containers",
        "unique_id": f"docker_{DEVICE_ID}_stopped",
        "state_topic": f"docker/{DEVICE_ID}/summary",
        "value_template": "{{ value_json.stopped }}",
        "device": device_info,
        "icon": "mdi:stop-circle"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/docker_{DEVICE_ID}/stopped/config"
    mqtt_client.publish(topic, json.dumps(stopped_config), retain=True)
    
    # SentryLab version (only once in summary)
    sentrylab_version_config = {
        "name": f"{DEVICE_NAME} SentryLab Version",
        "unique_id": f"docker_{DEVICE_ID}_sentrylab_version",
        "state_topic": f"docker/{DEVICE_ID}/summary",
        "value_template": "{{ value_json.sentrylab_version }}",
        "device": device_info,
        "icon": "mdi:information"
    }
    
    topic = f"{HA_BASE_TOPIC}/sensor/docker_{DEVICE_ID}/sentrylab_version/config"
    mqtt_client.publish(topic, json.dumps(sentrylab_version_config), retain=True)


def main():
    """Main execution"""
    logger.info("SentryLab-Docker Discovery starting...")
    logger.info(f"Device: {DEVICE_NAME} ({DEVICE_ID})")
    
    if DEBUG:
        logger.info("DEBUG mode enabled - no MQTT transmission")
    
    try:
        docker_client = docker.from_env()
        logger.info("Connected to Docker daemon")
        
        mqtt_client = setup_mqtt()
        
        import time
        if mqtt_client:
            time.sleep(2)
        
        containers = docker_client.containers.list(all=True)
        logger.info(f"Found {len(containers)} containers")
        
        publish_summary_discovery(mqtt_client)
        
        for container in containers:
            try:
                publish_container_discovery(mqtt_client, container)
            except Exception as e:
                logger.error(f"Error publishing discovery for {container.name}: {e}")
        
        if mqtt_client:
            time.sleep(2)
        
        logger.info(f"Discovery complete for {len(containers)} containers")
        
        if mqtt_client:
            mqtt_client.loop_stop()
            mqtt_client.disconnect()
        
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        raise


if __name__ == "__main__":
    main()