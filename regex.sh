# Regular expressions for validations
re_ip='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' # Regex: checks if the input is a valid IPv4 address.
re_port='^[1-9][0-9]*$' # Regex: checks if the input is a positive integer (greater than zero).
re_cidr='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' # Regex for CIDR block.
# Regexs for the current node's IP address.
re_device_ip_line='^\s+inet\s(\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b).*'
re_ip_numbers='\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b'
re_kver='Kubernetes\sv[0-9]+\.[0-9]+\.[0-9]+' # Regex for the kubernetes release version.
re_crds_ver='release-v[0-9]+\.[0-9]+\.[0-9]+' # Regex for the custom resources definitions release version.