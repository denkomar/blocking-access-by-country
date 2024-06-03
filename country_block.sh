#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0"
    exit 1
}

# Function to print info messages
function info {
    echo -e "\e[32m[INFO]\e[0m $1"
}

# Function to print error messages
function error {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# Function to install required packages
function install_packages {
    info "Updating package lists and installing required packages..."
    apt-get update -y
    apt-get install -y ipset iptables-persistent wget
}

# Function to list current rules
function list_rules {
    info "Current IPSet and IPTables rules:"
    local index=1
    ipset list -name | grep -E "^country_" | while read -r set; do
        echo "$index. $set"
        index=$((index + 1))
    done
}

# Function to delete all rules
function delete_all_rules {
    info "Deleting all IPSet and IPTables rules created by this script..."

    # Loop through all IPSet sets that start with 'country_'
    ipset list -name | grep -E "^country_" | while read -r set; do
        info "Processing set $set..."

        # Explicitly delete the rule if it exists
        while iptables -C INPUT -p tcp -m tcp --dport 22 -m set --match-set $set src -j DROP 2>/dev/null; do
            iptables -D INPUT -p tcp -m tcp --dport 22 -m set --match-set $set src -j DROP
            info "Deleted rule for set $set"
        done

        sleep 1 # Add a small delay to ensure rules are deleted before flushing the set

        # Verify that no rules are using the set
        if iptables-save | grep -q -- "--match-set $set src"; then
            error "Failed to remove all rules referencing set $set"
            iptables-save | grep -- "--match-set $set src"
        else
            # Flush the IPSet set
            if ipset flush $set; then
                info "Set $set flushed successfully."
            else
                error "Failed to flush set $set. It might still be in use."
            fi

            # Destroy the IPSet set
            if ipset destroy $set; then
                info "Set $set destroyed successfully."
            else
                error "Failed to destroy set $set. It might still be in use."
                ipset list $set
            fi
        fi
    done

    info "All IPSet and IPTables rules deleted."
}

# Function to delete selected rules
function delete_selected_rules {
    info "Listing current rules:"
    list_rules
    read -p "Enter the numbers of the IPSet names to delete (comma-separated): " DELETE_SETS
    for SET_NUM in $(echo $DELETE_SETS | tr ',' ' '); do
        SET_NAME=$(ipset list -name | grep -E "^country_" | sed -n "${SET_NUM}p")
        if [ -n "$SET_NAME" ]; then
            iptables-save | grep -E "\-A INPUT -p tcp -m set --match-set $SET_NAME src -j DROP" | while read -r line; do
                iptables -D ${line#-A }
            done
	    sleep 5
            ipset flush $SET_NAME
            ipset destroy $SET_NAME
            info "Deleted IPSet and IPTables rules for $SET_NAME"
        else
            error "Invalid selection: $SET_NUM"
        fi
    done
}

# Function to prompt user for countries to block
function prompt_for_countries {
    read -p "Enter the country codes to block (comma-separated, e.g., CN,RU,SG): " COUNTRY_CODES
}

# Function to prompt user for ports
function prompt_for_ports {
    read -p "Enter the ports to block (comma-separated, default: ssh): " PORTS
    PORTS=${PORTS:-ssh}
}

# Check if ipset is installed
if ! command -v ipset &> /dev/null; then
    info "ipset is not installed. Installing necessary packages..."
    install_packages
else
    # Check for existing rules and prompt the user
    list_rules
    read -p "Press Enter to continue, 'd' to delete all rules, 's' to delete selected rules: " CHOICE
    case $CHOICE in
        d) delete_all_rules ;;
        s) delete_selected_rules ;;
        *) ;;
    esac
fi

# Prompt user for country codes and ports
prompt_for_countries
prompt_for_ports

info "Starting setup of IP blocking for countries: $COUNTRY_CODES and ports: $PORTS"

info "Creating setup script for IPSet and IPTables..."
cat << EOF > /usr/local/bin/setup_ipset.sh
#!/bin/bash

IPSET_NAME_PREFIX="country_"
IPSET_TMP="/tmp/country.zone"

function info {
    echo -e "\e[32m[INFO]\e[0m \$1"
}

function error {
    echo -e "\e[31m[ERROR]\e[0m \$1"
}

COUNTRY_CODES="$COUNTRY_CODES"
PORTS="$PORTS"

for COUNTRY in \$(echo \$COUNTRY_CODES | tr ',' ' '); do
    IPSET_NAME="\${IPSET_NAME_PREFIX}\${COUNTRY}"

    if ipset list -n | grep -q "\$IPSET_NAME"; then
        info "IPSet \$IPSET_NAME already exists. Skipping creation."
    else
        info "Creating IPSet named \$IPSET_NAME..."
        ipset create \$IPSET_NAME hash:net

        info "Downloading IP list for country \$COUNTRY..."
        wget -q -O \$IPSET_TMP http://www.ipdeny.com/ipblocks/data/countries/\${COUNTRY}.zone

        if [ -s \$IPSET_TMP ]; then
            info "Adding IP addresses to IPSet \$IPSET_NAME..."
            while read -r ip; do
                ipset add \$IPSET_NAME \$ip
            done < \$IPSET_TMP
        else
            error "Failed to download IP list for country \$COUNTRY"
            exit 1
        fi
    fi

    for PORT in \$(echo \$PORTS | tr ',' ' '); do
        if ! iptables-save | grep -q "\-A INPUT -p tcp -m set --match-set \$IPSET_NAME src -j DROP"; then
            info "Adding IPSet rule to IPTables for port \$PORT..."
            iptables -I INPUT -p tcp --dport \$PORT -m set --match-set \$IPSET_NAME src -j DROP
        else
            info "IPTables rule for \$IPSET_NAME and port \$PORT already exists. Skipping."
        fi
    done
done
EOF

info "Making setup script executable..."
chmod +x /usr/local/bin/setup_ipset.sh

info "Creating systemd service for IPSet and IPTables setup..."
cat << EOF > /etc/systemd/system/setup_ipset.service
[Unit]
Description=Setup IPSet and IPTables for countries: $COUNTRY_CODES and ports: $PORTS
After=network.target

[Service]
ExecStart=/usr/local/bin/setup_ipset.sh
Type=oneshot
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

info "Reloading systemd daemon and enabling service..."
systemctl daemon-reload
systemctl enable setup_ipset.service

info "Creating script for updating IPSet..."
cat << EOF > /usr/local/bin/update_ipset.sh
#!/bin/bash

IPSET_NAME_PREFIX="country_"
IPSET_TMP="/tmp/country.zone"

function info {
    echo -e "\e[32m[INFO]\e[0m \$1"
}

function error {
    echo -e "\e[31m[ERROR]\e[0m \$1"
}

COUNTRY_CODES="$COUNTRY_CODES"

for COUNTRY in \$(echo \$COUNTRY_CODES | tr ',' ' '); do
    IPSET_NAME="\${IPSET_NAME_PREFIX}\${COUNTRY}"

    info "Downloading updated IP list for country \$COUNTRY..."
    wget -q -O \$IPSET_TMP http://www.ipdeny.com/ipblocks/data/countries/\${COUNTRY}.zone

    if [ -s \$IPSET_TMP ]; then
        info "Flushing old IP addresses from IPSet \$IPSET_NAME..."
        ipset flush \$IPSET_NAME
        info "Adding new IP addresses to IPSet \$IPSET_NAME..."
        while read -r ip; do
            ipset add \$IPSET_NAME \$ip
        done < \$IPSET_TMP
    else
        error "Failed to download IP list for country \$COUNTRY"
        exit 1
    fi
done
EOF

info "Making update script executable..."
chmod +x /usr/local/bin/update_ipset.sh

info "Adding cron job for updating IPSet..."
(crontab -l ; echo "0 2 * * * /usr/local/bin/update_ipset.sh") | crontab -

info "Running initial setup script..."
/usr/local/bin/setup_ipset.sh

info "Setup complete. IP blocking for specified countries and ports is now enabled."
info "Displaying statistics:"
ipset list | grep -E "^Name|^Members:"
iptables -L -v -n | grep -E "DROP.*country_"
