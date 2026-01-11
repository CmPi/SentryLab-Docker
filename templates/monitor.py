#!/usr/bin/env python3

"""
@file monitoring.py
@author CmPi <github.com/CmPi>
@brief Docker Container Monitoring Script
@date 2025-01-11
@version 1.0.0

Continuously monitors Docker containers and publishes status to MQTT
"""

import os
import time
import json
import logging
from datetime import datetime, timezone

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
DEVICE_ID = os.getenv("DEVICE_ID", "docker_host")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "30"))
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
        logger.error(f"Failed to connect. Return code: {rc}")


def on_disconnect(client, userdata, rc):
    """MQTT disconnection callback"""
    if rc != 0:
        logger.warning(f"Unexpected disconnection. Return code: {rc}")


def setup_mqtt():
    """Initialize and connect to MQTT broker"""
    if DEBUG:
        logger.info("DEBUG mode: MQTT publishing disabled")
        return None
    
    client = mqtt.Client()
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    
    if USER and PASS:
        client.username_pw_set(USER, PASS)
    
    try:
        client.connect(BROKER, PORT, 60)
        client.loop_start()
        return client
    except Exception as e:
        logger.error(f"Failed to connect to MQTT broker: {e}")
        raise


def calculate_uptime(started_at_str):
    """Calculate container uptime from start time"""
    if not started_at_str or started_at_str == "0001-01-01T00:00:00Z":
        return "Not started"
    
    try:
        started_at = datetime.fromisoformat(started_at_str.replace('Z', '+00:00'))
        now = datetime.now(timezone.utc)
        uptime_delta = now - started_at
        
        days = uptime_delta.days
        hours, remainder = divmod(uptime_delta.seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        
        if days > 0:
            return f"{days}d {hours}h {minutes}m"
        elif hours > 0:
            return f"{hours}h {minutes}m"
        else:
            return f"{minutes}m {seconds}s"
    except Exception as e:
        logger.debug(f"Error calculating uptime: {e}")
        return "Unknown"


def get_container_state(container):
    """Get detailed container state information"""
    try:
        container.reload()
        attrs = container.attrs
        state = attrs["State"]
        
        health = "N/A"
        if "Health" in state:
            health = state["Health"].get("Status", "N/A")
        
        image = attrs["Config"]["Image"]
        started_at = state.get("StartedAt", "")
        uptime = calculate_uptime(started_at)
        
        # Get image version/tag
        try:
            image_full = container.image.tags[0] if container.image.tags else image
            if ":" in image_full:
                image_name, image_version = image_full.rsplit(":", 1)
            else:
                image_name = image_full
                image_version = "latest"
        except:
            image_name = image
            image_version = "unknown"
        
        return {
            "running": state.get("Running", False),
            "state": state.get("Status", "unknown"),
            "health": health,
            "image": image,
            "image_version": image_version,
            "uptime": uptime,
            "started_at": started_at,
            "pid": state.get("Pid", 0),
            "exit_code": state.get("ExitCode", 0),
            "error": state.get("Error", ""),
            "timestamp": datetime.utcnow().isoformat()
        }
    except Exception as e:
        logger.error(f"Error getting state for {container.name}: {e}")
        return None


def publish_container_state(mqtt_client, container):
    """Publish container state to MQTT"""
    state = get_container_state(container)
    
    if state:
        topic = f"docker/{DEVICE_ID}/{container.name}/state"
        payload = json.dumps(state)
        
        if mqtt_client is None and DEBUG:
            logger.debug(f"DEBUG: Would publish to {topic}: {state['state']}")
        elif mqtt_client:
            mqtt_client.publish(topic, payload, retain=True)
            logger.debug(f"Published state for {container.name}: {state['state']}")


def publish_summary(mqtt_client, containers):
    """Publish summary statistics"""
    running = sum(1 for c in containers if c.status == "running")
    stopped = len(containers) - running
    
    summary = {
        "total": len(containers),
        "running": running,
        "stopped": stopped,
        "sentrylab_version": SENTRYLAB_VERSION,
        "timestamp": datetime.utcnow().isoformat()
    }
    
    topic = f"docker/{DEVICE_ID}/summary"
    payload = json.dumps(summary)
    
    if mqtt_client is None and DEBUG:
        logger.debug(f"DEBUG: Would publish summary: {running}/{len(containers)} running, SentryLab v{SENTRYLAB_VERSION}")
    elif mqtt_client:
        mqtt_client.publish(topic, payload, retain=True)
        logger.debug(f"Published summary: {running}/{len(containers)} running")


def monitor_containers(docker_client, mqtt_client):
    """Monitor all containers and publish their state"""
    try:
        containers = docker_client.containers.list(all=True)
        logger.info(f"Monitoring {len(containers)} containers...")
        
        publish_summary(mqtt_client, containers)
        
        for container in containers:
            try:
                publish_container_state(mqtt_client, container)
            except Exception as e:
                logger.error(f"Error monitoring {container.name}: {e}")
        
        logger.info(f"Updated status for {len(containers)} containers")
        
    except Exception as e:
        logger.error(f"Error monitoring containers: {e}")


def main():
    """Main monitoring loop"""
    logger.info("SentryLab- Monitoring starting...")
    logger.info(f"Version: {SENTRYLAB_VERSION}")
    logger.info(f"Device ID: {DEVICE_ID}")
    logger.info(f"Poll Interval: {POLL_INTERVAL}s")
    
    if DEBUG:
        logger.info("DEBUG mode enabled - no MQTT transmission")
    
    try:
        docker_client = docker.from_env()
        logger.info("Connected to Docker daemon")
        
        mqtt_client = setup_mqtt()
        
        if mqtt_client:
            time.sleep(2)
        
        while True:
            monitor_containers(docker_client, mqtt_client)
            logger.info(f"Sleeping for {POLL_INTERVAL} seconds...")
            time.sleep(POLL_INTERVAL)
            
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        raise
    finally:
        if mqtt_client and mqtt_client is not None:
            mqtt_client.loop_stop()
            mqtt_client.disconnect()
        logger.info("Monitoring stopped")


if __name__ == "__main__":
    main()