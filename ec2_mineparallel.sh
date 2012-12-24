#!/bin/bash 
trap "kill 0" SIGINT  #important to kill background tasks1

LOCALTUNNELPORT="25565"
EC2MINECRAFTPORT="25565"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes"
SSH_IDENTIFY="-i $HOME/.ssh/<YOUR AWS SSH PRIVATEKEY>.pem"
SSH_FORWARD="-g -L$LOCALTUNNELPORT:localhost:$EC2MINECRAFTPORT"
INSTANCE="<YOUR AWS INSTANCE ID> "   #TODO:Make this a parameter
IP=""  #IP is an important global

# EC2 utilities expect the following environment variables to be set: Minecraft
#EC2_KEYPAIR  - name of EC2-configure keypair to enable for new EC2 instance startups
#EC2_URL - API endpoint for your EC2 availability region: https://ec2.us-east-1.amazonaws.com   
#EC2_PRIVATE_KEY - path to .pem file with your AWS private key:  pk-XXXXXX.pem
#EC2_CERT - path to .pem with your AWS certificate:  cert-XXXXX.pe,

if [ -e ~/.ec2_minecraft ] ; then
  source ~/.ec2_minecraft ;  # OVERRIDE THE DEFAULTS above in a separate file for security
fi

function set_status()
{
    #TODO MAKE THIS PARAMETERIZED
    echo "Set status"    
    ln -f server$1.dmp currentstatus.dmp
}

function release_ip()
{
    echo "Checking for Elastic IP to release"
    ADDRESS_TEXT=`ec2-describe-addresses`
    if [[ $ADDRESS_TEXT != "" ]]; 
    then 
	INACTIVE_IP=$(echo "$ADDRESS_TEXT" | grep -v $INSTANCE | cut -f2)
	if [[ $INACTIVE_IP != "" ]] ; then 
	    echo "Releasing Unassociated IP: $INACTIVE_IP"
            ec2-release-address $INACTIVE_IP; 
	fi
    fi
}

function watch_for_unassociated_ip() {
    while true; 
    do {
	    release_ip
	    sleep 60 
    } done

}

function allocate_ip() 
{
    echo "Allocating Elastic IP"
    HOSTNAME=`ec2-allocate-address | cut -f2`
    IP="$HOSTNAME"
}

function serve_fake_availability()
{
    echo "Serve Fake Availability"
    nc -l $LOCALTUNNELPORT <currentstatus.dmp  >/dev/null
}

function run_ssh_when_server_up()
{
    echo "Is EC2 Minecraft there?"
    until { nc -w1 -vz $IP $EC2MINECRAFTPORT ; } do  {
	echo "Waiting for Minecraft to be available"
	serve_fake_availability serverstarting.dump   #needs end user interaction; TODO:  have EC2 Server ping this
    } done
    
    echo "Minecraft is listening"
    echo "Creating SSH Tunnel to $HOSTNAME"
    ssh ec2-user@$IP  $SSH_IDENTIFY $SSH_FORWARD $SSH_OPTIONS "echo 2 >.prev_count; sleep 300"
    echo "SSH Tunnel has closed"
}

function check_for_running_ec2() {
    echo 'Checking for already running ec2'
    SERVER_STATUS="`ec2-describe-instances $INSTANCE | grep INSTANCE`"
    IP=$(echo "$SERVER_STATUS" | cut -f17)
    MC_RUNNING=$(echo "$SERVER_STATUS" | cut -f6 )
    echo "$INSTANCE: $MC_RUNNING  $IP"
}

function start_ec2_server_if_necessary() {
    if  nc -w1 -vz $IP $EC2MINECRAFTPORT ; 
    then
	echo "EC2 already running";
	set_status 7
    else
	echo "Starting EC2"  #TODO: Enhance to more gracefully detect starting up while shutting down
	set_status 4
	ec2-start-instances $INSTANCE 
	set_status 5
	#TODO  Wait until ec2 instance is in "running state"
	ec2-associate-address $IP -i $INSTANCE 
	set_status 6
    fi
}

watch_for_unassociated_ip & # background this loop

while true; do
    echo "Holding waiting for status check (nossh)"
    set_status 0
    serve_fake_availability serverup.dmp  #hold until someone checks on "server status"
    set_status 1
    check_for_running_ec2
    set_status 2
    if [[ $IP == "" ]]; then allocate_ip; fi
    set_status 3
    
    # Background the work to start the server if necessary
    start_ec2_server_if_necessary &

    run_ssh_when_server_up # poll on ec2 port then launch ssh tunnel

done;


