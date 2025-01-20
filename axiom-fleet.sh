
#!/usr/bin/env bash

###################################################################
# About :
#
# axiom-fleet lets you spin up fleets of axiom instances in one or multiple regions.
# You can specify the name of a fleet (fleet prefix) or have axiom choose for you.
#
# Examples:
#
# axiom-fleet # Spin up three instances, let axiom decide on the fleet prefix"
# axiom-fleet javis -i 10 # Spin up 10 instances with a fleet prefix of javis, this will create 10 instances named javis01 to javis10."
# axiom-fleet jerry -i 25 --regions dal13,lon06,fra05,tok05,syd05 # Spin up 25 instances using round robbin region distribution"

###########################################################################################################
# Header
#
AXIOM_PATH="$HOME/.axiom"
source "$AXIOM_PATH/interact/includes/vars.sh"
source "$AXIOM_PATH/interact/includes/functions.sh"
source "$AXIOM_PATH/interact/includes/system-notification.sh"
BASEOS="$(uname)"
case $BASEOS in
'Darwin')
    PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"
    ;;
*) ;;
esac

###########################################################################################################
# Declare defaut variables
#
spend=false
hours=false
amount=false
prompt=false
region=false
image=false
cycle_regions=false
region_array=()
gen_name=""
provider="$(jq -r ".provider" "$AXIOM_PATH"/axiom.json)"
image="$(jq -r '.imageid' "$AXIOM_PATH"/axiom.json)"
region="$(jq -r '.region' "$AXIOM_PATH"/axiom.json)"
sshkey="$(jq -r '.sshkey' "$AXIOM_PATH"/axiom.json)"
image_id=""
instances=false
time=320
init_timeout=4
init_sleep=4
manual_image_id=false

###########################################################################################################
# DO Region Transfer
# Transfer image to region if requested in that region yet does not exist. DO only
#
region_transfer() {
    # DigitalOcean region transfer logic
    if [[ "$provider" == "do" ]]; then
        avail_image_id_regions=$(doctl compute image get "$image_id" -o json | jq -r '.[] | .regions[]')
        requested_image_id_regions="$regionargs"
        if [[ "$avail_image_id_regions" != *"$requested_image_id_regions"* ]]; then
            echo -e "${Color_Off}]"
            echo -e "${BYellow}Instance ${BGreen}"$name"${BYellow} requested image in region ${BRed}$regionargs${BYellow}, but image ${BRed}$image${BYellow} only exists in ${BRed}$(echo $avail_image_id_regions | tr '\n' ',')"
            echo -e "${BYellow}Attempting to transfer image to the requested region. This may take a few minutes...${Color_Off}"
            doctl compute image-action transfer "$image_id" --region "$regionargs" --wait
            if [ $? -eq 0 ]; then
                echo -e "\033[32mImage transfer succeeded.\033[0m"
                echo -e "${BWhite}Waiting 90 seconds before continuing...${Color_Off}"
                sleep 90
            else
                echo -e "${BRed}Image transfer failed. Consider using a different region. Run '${BWhite}axiom-region ls${BRed}' to list regions or '${BWhite}axiom-images ls${BRed}' to list images.${Color_Off}"
            fi
        fi
        echo -n -e "${BWhite}Instances: ${Color_Off}[ ${BGreen}"
    fi

    # AWS region transfer logic
    if [[ "$provider" == "aws" ]]; then
        echo "Checking if AMI $image exists in region $regionargs..."
        existing_ami=$(aws ec2 describe-images --region "$regionargs" \
            --filters "Name=name,Values=$(jq -r '.name' "$AXIOM_PATH"/axiom.json)" \
            --query 'Images[0].ImageId' --output text 2>/dev/null)

        if [[ "$existing_ami" == "None" || -z "$existing_ami" ]]; then
            echo -e "AMI not found in $regionargs. Starting transfer process..."
            new_ami=$(aws ec2 copy-image --source-region "$region" \
                --source-image-id "$image" \
                --region "$regionargs" \
                --name "$(jq -r '.name' "$AXIOM_PATH"/axiom.json)" \
                --description "Copied AMI to $regionargs" \
                --query 'ImageId' --output text)

            if [ $? -eq 0 ]; then
                echo -e "AMI transfer succeeded. New AMI ID in $regionargs: $new_ami"
                echo "Waiting for the new AMI to become available..."
                aws ec2 wait image-available --image-ids "$new_ami" --region "$regionargs"
                echo -e "AMI $new_ami is now available in $regionargs."
            else
                echo -e "AMI transfer failed. Check your AWS settings and try again."
                exit 1
            fi
        else
            echo -e "AMI $image already exists in $regionargs with ID: $existing_ami"
        fi
    fi
}


###########################################################################################################
# Help Menu
# 
function usage() {
        echo -e "${BWhite}Description:${Color_Off}"
        echo -e "  Spin up fleets of axiom instances in one or multiple regions."
        echo -e "  Specify the name of your fleet (fleet prefix) or have axiom choose for you."
        echo -e "${BWhite}Examples:${Color_Off}"
        echo -e "  ${BGreen}axiom-fleet ctbb ${Color_Off} # Spin up 3 instances named ctbb01 ctbb02 and ctbb03"
        echo -e "  ${BGreen}axiom-fleet -i 10${Color_Off} # Spin up 10 instances with random fleet prefix"
        echo -e "  ${BGreen}axiom-fleet jerry -i 25 --regions dal13,lon06,fra05${Color_Off} # Spin up 25 instances named jerry01 to jerry25 using Round-robin region distribution"
        echo -e "${BWhite}Usage:${Color_Off}"
        echo -e "  <fleet prefix> (optional)"
        echo -e "    Name of fleet prefix (default is random fleet prefix)"
        echo -e "  -i/--instances <required integer>"
        echo -e "    The number of instances to spin up"
        echo -e "  -r/--regions <regions> (optional)"
        echo -e "    Supply comma-separated regions to cycle through (default is region in ~/.axiom/axiom.json)"
        echo -e "  --image <image name> (optional)"
        echo -e "    Manually set the image to use (default is imageid in ~/.axiom/axiom.json)"
        echo -e "  --debug (optional)"
        echo -e "    Run with set -xv, warning: very verbose"
        echo -e "  --help (optional)"
        echo -e "    Display this help menu"
}

###########################################################################################################
# Parse command line arguments
#
if [ $# -eq 0 ]; then
    usage
    exit 0
fi
i=0
for arg in "$@"
do
    if [[ "$arg" == "--help" ]] || [[ "$arg" == "-h" ]] ; then
	usage
	exit
    fi
    i=$((i+1))
    if [[  ! " ${pass[@]} " =~ " ${i} " ]]; then
        set=false
        if [[ "$arg" == "--debug" ]]; then
            set -xv
            set=true
            pass+=($i)
        fi
        if [[ "$arg" == "-i" ]] || [[ "$arg" == "--instances" ]]; then
            n=$((i+1))
            instances=true
            amount=$(echo ${!n})
            set=true
            pass+=($i)
            pass+=($n)
        fi
        if [[ "$arg" == "--regions" ]] || [[ "$arg" == "-r" ]]; then
            n=$((i+1))
            cycle_regions=$(echo ${!n})
            set=true
            pass+=($i)
            pass+=($n)
        fi
        if [[ "$arg" == "--image" ]] ; then
            n=$((i+1))
            image=$(echo ${!n})
            set=true
            pass+=($i)
            pass+=($n)
	fi
        if [[ "$arg" == "--image-id" ]]; then
            n=$((i+1))
            manual_image_id=$(echo ${!n})
            set=true
            pass+=($i)
            pass+=($n)
        fi
        if  [[ "$set" != "true" ]]; then
            space=" "
            if [[ $arg =~ $space ]]; then
              args="$args \"$arg\""
            else
              args="$args $arg"
            fi
        fi
    fi
done

###########################################################################################################
# If -i /--instances isnt used, default to three instances
#
if [[ "$amount" == "false" ]]; then
 amount=3
fi

###########################################################################################################
# Generate name
#
if [ -z ${args+x} ]; then 
 gen_name="${names[$RANDOM % ${#names[@]} ]}"
else
 gen_name=$(echo "$args" | tr -d ' ')
fi

###########################################################################################################
# Change init_sleep as needed
#
if [[ "$provider" == "linode" ]]; then
 init_sleep=6
fi

###########################################################################################################
# Get image_id from $image ( default is from axiom.json ) or from user supplied manual image id param
#
if [ "$manual_image_id" != "false" ]
then
    image_id="$manual_image_id"
else
    image_id="$(get_image_id "$image")"
    if [ -z "$image_id" ]; then
        echo -e "${BRed}ERROR: imageid ${Color_Off}[ ${BBlue}$image ${Color_Off}]${BRed} not found in ${Color_Off}[ ${BBlue}~/.axiom/axiom.json ${Color_Off}]${BRed}. you may need to run ${Color_Off}[ ${BBlue}axiom-build --setup ${Color_Off}]${BRed} to build a new image."
        echo -e "${BRed}if you've already built an image, list all images with ${Color_Off}[ ${BBlue}axiom-images ls ${Color_Off}]${BRed} and select it with ${Color_Off}[ ${BBlue}axiom-images select axiom-\$provisioner-\$timestamp ${Color_Off}]"
        echo -e "${BRed}exiting...${Color_Off}"
        exit 1
    fi
fi

###########################################################################################################
# Check if ssh key is specified in axiom.json
#
if [ "$sshkey" == "" ] || [ "$sshkey" == "null" ]; then
echo -e  "${BYellow}WARNING: sshkey not found in ${Color_Off}[ ${BBlue}~/.axiom/axiom.json ${Color_Off}]${BYellow}. adding ${Color_Off}[ ${BBlue}axiom_rsa ${Color_Off}] ${BYellow}key as a backup."
account_path=$(ls -la "$AXIOM_PATH"/axiom.json | rev | cut -d " " -f 1 | rev)
sshkey=axiom_rsa
 if [ -f ~/.ssh/axiom_rsa ] ; then
  jq '.sshkey="'axiom_rsa'"' <"$account_path">"$AXIOM_PATH"/tmp.json ; mv "$AXIOM_PATH"/tmp.json "$account_path"

 else
  ssh-keygen -b 2048 -t rsa -f ~/.ssh/axiom_rsa -q -N ""
  jq '.sshkey="'axiom_rsa'"' <"$account_path">"$AXIOM_PATH"/tmp.json ; mv "$AXIOM_PATH"/tmp.json "$account_path"  >> /dev/null 2>&1
 fi
fi


###########################################################################################################
# Initialize fleet
#
if [[ "$cycle_regions" == "false" ]]; then

# Chance to cancel initialization of fleet
#
echo -e "${BWhite}Initializing new fleet '${BGreen}$gen_name${BWhite}' with '${BGreen}$amount${BWhite}' instances using image '${BGreen}$image${BWhite}' in region '${BGreen}$region${BWhite}'${Color_Off}...${Color_Off}"
echo -e "${BWhite}INITIALIZING IN 5 SECONDS, CTRL+C to quit... ${Color_Off}"
sleep 5

total=$(query_instances "$gen_name*" | tr " " "\n" | sed 's/[^0-9]*//g'| sort -nr | head -n1)
total="${total#0}"
start="${start#0}"
start=$((total))
amount=$(($amount+$start))
start=$((start+1))
total_spend_per_instance_rounded="0"
slug=$(cat "$AXIOM_PATH"/axiom.json | jq -r .default_size)  >/dev/null 2>&1

echo -n -e "${BWhite}Instances: ${Color_Off}[ ${BGreen}"
o=0
for i in $(seq -f "%02g" $start $amount)
do
 time=$((time+3))
 name="$gen_name$i"
 echo -n -e "${BGreen}$name ${Color_Off}"
 args=""
"$AXIOM_PATH"/interact/axiom-init "$name" --quiet --size "$slug" --image-id "$image_id" --no-select --region  "$region" &
sleep $init_sleep
o=$((o+1))
done
echo -n -e "${Color_Off} ]\n"

while [[ $time -gt 0 ]]; do
    echo -ne ">> T-Minus $time to fleet $gen_name initialization...\033[0K\r"
    sleep 1
    : $((time--))
done
fi

###########################################################################################################
# Round Robin distribution logic here ( i.e. regions_to_cycle)
#
if [[ "$cycle_regions" != "false" ]]; then

###########################################################################################################
# Chance to cancel initialization of fleet
#
echo -e "${BWhite}Initializing new fleet '${BGreen}$gen_name${BWhite}' with '${BGreen}$amount${BWhite}' instances using image '${BGreen}$image${Color_Off}'...${Color_Off}"
echo -e "${BWhite}Cycling through following regions:${BGreen}$cycle_regions${BWhite}...${Color_Off}"
echo -e "${BWhite}INITIALIZING IN 5 SECONDS, CTRL+C to quit... ${Color_Off}"
sleep 5
total=$(query_instances "$gen_name*" | tr " " "\n" | sed 's/[^0-9]*//g'| sort -nr | head -n1)
total="${total#0}"
start="${start#0}"
start=$((total))
amount=$(($amount+$start))
start=$((start+1))
total_spend_per_instance_rounded="0"
slug=$(cat "$AXIOM_PATH"/axiom.json | jq -r .default_size)  >/dev/null 2>&1

IFS=',' read -r -a region_array <<< "$cycle_regions"

# Basically repeat items, if the fleet is 20 hosts and they only supply 3 regions, loop over them until it reaches 20
total_regions=$(echo "${region_array[@]}" |  tr ' ' '\n' | wc -l | awk '{ print $1 }')
regions_to_cycle=()
 k=0
 while [[ "$(echo ${regions_to_cycle[@]} | tr ' ' '\n' | wc -l | awk '{ print $1}')" -lt "$amount" ]]
 do
  regions_to_cycle+=("${region_array[k]}")
  if [[ "$k" -lt "$total_regions" ]]; then
   k=$((k+1))
  else
   k=0
  fi
done

# Remove null element from array and reindex
#
for i in "${!regions_to_cycle[@]}"; do
  [ -n "${regions_to_cycle[$i]}" ] || unset "regions_to_cycle[$i]" && regions_to_cycle=( "${regions_to_cycle[@]}" )
done

echo -n -e "${BWhite}Instances: ${Color_Off}[ ${BGreen}"
o=0
for i in $(seq -f "%02g" $start $amount)
do
time=$((time+3))
name="$gen_name$i"
echo -n -e "${BGreen}$name ${Color_Off}"
args=""
regionargs="${regions_to_cycle[o]}"

# final check to make sure region is set
#
if [ -z ${regionargs:+x} ]; then
regionargs="$(jq -r '.region' "$AXIOM_PATH"/axiom.json)"
fi

###########################################################################################################
# DO Region Transfer
# Transfer image to region if requested in that region yet does not exist. DO only
#
if [[ "$provider" == "aws" ]]; then
  region_transfer
fi

# create instance
#
"$AXIOM_PATH"/interact/axiom-init "$name" --quiet --size "$slug" --image-id "$image_id" --no-select --region  "$regionargs" &
sleep $init_sleep
o=$((o+1))
done
echo -n -e "${Color_Off} ]\n"
fi

while [[ $time -gt 0 ]]; do
 echo -ne ">> T-Minus $time to fleet $gen_name initialization...\033[0K\r"
 sleep 1
 : $((time--))
done
"$AXIOM_PATH"/interact/axiom-select "$gen_name*"

echo -e "${BGreen}Fleet started succesfully!\nTo delete your fleet, just run '${BGreen}axiom-rm \"$gen_name*\" -f${BGreen}'${Color_Off}"
