# raven-mqtt

Takes the XML messages from a RAVEn and writes them to MQTT

A RAVEn is the now discontinued USB device to talk to a smart meter. Appears
to the sytem as a USB serial port that you read/write XML from/to.

https://rainforestautomation.com/wp-content/uploads/2014/02/raven_xml_api_r127.pdf

## INSTALL

Copy main script and service definition:

```
cp raven-mqtt.pl /usr/bin/
cp raven-mqtt.service /etc/systemd/system/
```

Install dependencies:

```
apt install expat libexpat1-dev
cpan Device::SerialPort
cpan XML::Simple
cpan Net::MQTT::Simple
```

Set up the service:

```
systemctl start raven-mqtt
systemctl enable raven-mqtt
systemctl status raven-mqtt
```

