#!/bin/bash

#domains=(example.com www.example.com)
domain=""
rsa_key_size=4096
data_path="./data/certbot"
email="" # Adding a valid address is strongly recommended
staging=0 # Set to 1 if you're testing your setup to avoid hitting request limits
app_conf_path="data/nginx/app.conf"
usage="$(basename "$0") [-h|--help] [-d|--domain DOMAIN_NAME] [--email EMAIL] [--rsa-key-size RSA_KEY_SIZE] [--data-dir DATA_DIR]
	where:
		-h, --help       show this help text
		-d|--domain      followed by domain name to generate cert for
		--email     	 Email for the certificate
		--rsa-key-size   New rsa key size, default 4096
		--data-dir		 Directory with the nginx configuation files"


while :
do
	case "$1" in
		-h|--help)
			echo "$usage" >&2 
			exit 0
			;;
		-d|--domain)
			shift 1
			domain=$1
			shift 1
			;;
		--rsa-key-size)
			shift 1
			rsa_key_size=$1
			shift 1
			;;
		--data-dir)
			shift 1
			data_path=$1
			shift 1
			;;
		--email)
			shift 1
			email=$1
			shift 1
			;;
		  --) # End of all options
			  shift
			  break
			  ;;
		  -*)
			  echo "Error: Unknown option: $1" >&2
			  echo "$usage" >&2 
			  exit 1
			  ;;
		  *)  # No more options
			  break
			  ;;
		
	esac
done

if [[ -z  $domain  ]]; then
	   echo "domain cannot be empty. See usage"
	   echo "$usage" >&2 
	   exit
fi

if [ -d "$data_path" ]; then
  read -p "Existing data found for $domain. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

# check nginx configuration file
if [ ! -f "$app_conf_path" ]; then
	echo "Missing $app_conf_path file" >&2
	exit
fi

# run sed command
sed -i "s/<DOMAIN_NAME>/$domain/g" $app_conf_path


if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

echo "### Creating dummy certificate for $domain ..."
path="/etc/letsencrypt/live/$domain"
mkdir -p "$data_path/conf/live/$domain"

# create app network
docker network create app_net || true

docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:1024 -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo


echo "### Starting nginx ..."
docker-compose up --force-recreate -d nginx
echo

echo "### Deleting dummy certificate for $domain ..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domain && \
  rm -Rf /etc/letsencrypt/archive/$domain && \
  rm -Rf /etc/letsencrypt/renewal/$domain.conf" certbot
echo


echo "### Requesting Let's Encrypt certificate for $domain ..."
#Join $domains to -d args
#domain_args=""
#for domain in "${domains[@]}"; do
#  domain_args="$domain_args -d $domain"
#done

domain_args=""
domain_args="$domain_args -d $domain"

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot
echo

echo "### Reloading nginx ..."
docker-compose exec nginx nginx -s reload
