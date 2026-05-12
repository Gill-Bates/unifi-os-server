Ports
Protocol	Port	Direction	Usage
TCP	11443	Ingress	UniFi OS Server GUI/API
TCP	5005	Ingress	RTP (Real-time Transport Protocol) control protocol
TCP	9543	Ingress	UniFi Identity Hub
TCP	6789	Ingress	UniFi mobile speed test
TCP	8080	Ingress	Device and application communication
TCP	8443	Ingress	UniFi Network Application GUI/API
TCP	8444	Ingress	Secure Portal for Hotspot
UDP	3478	Both	STUN for device adoption and communication (also required for Remote Management)
UDP	5514	Ingress	Remote syslog capture
UDP	10003	Ingress	Device discovery during adoption
TCP	11084	Ingress	UniFi Site Supervisor
TCP	5671	Ingress	AQMPS
TCP	8880	Ingress	Hotspot portal redirection (HTTP)
TCP	8881	Ingress	Hotspot portal redirection (HTTP)
TCP	8882	Ingress	Hotspot portal redirection (HTTP)