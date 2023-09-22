#!/bin/sh

no_args="true"
declare -a restored_namespaces=()

# COLOR CONSTANTS
#LIGHT_BLUE='\033[1;34m'
#GREEN='\033[0;32m'
#RED='\033[0;31m'
#YELLOW='\033[0;33m'
#NC='\033[0m'

BLUE='\033[0;94m'
GREEN='\033[0;92m'
YELLOW='\033[0;93m'
RED='\033[0;31m'
NC='\033[0m'


print_heading()
{
    printf "${BLUE}$1${NC}\n"
}

print_info()
{
    printf "${GREEN}$1${NC}\n"
}

print_warning()
{
    printf "${YELLOW}$1${NC}\n"
}

print_error()
{
    printf "${RED}$1${NC}\n"
}

usageFunction()
{
   print_error "Error - Invalid parameters passed to the script"
   print_error "Usage: $0 -n <namespaces to restore>  [-t timeout] "
   print_error "-n (required) specifies the namespaces to be restored. Multiple namespaces can be provided separated by comma"
   print_error "-t (optional) specifies the timeout value in seconds. The script will check for status of restored namespaces until this timeout is reached"
   exit 1
}

# Validate if the provided storage class exist on the k8s cluster

# Creates a Namespace if one doesn't exist on the k8s cluster
createNamespace()
{
  print_info "Creating Namespace $ns "
  kubectl create ns $ns
  if [ $? -ne 0 ]; then
    print_error "Error - Failed to create the Namespace $ns. Exiting"
    exit 1
  fi
}

# Creates a RestorePoint using the latest RestorePointContent
createRPfromRPC()
{
  print_info "Creating RestorePoint for Namespace $ns"
  if [ `kubectl -n $ns get restorepoint --no-headers 2>/dev/null | wc -l ` -eq 0 ] 
  then
        restorepointcontentname=`kubectl get restorepointcontent -l k10.kasten.io/appNamespace=$ns --no-headers | awk 'NR==1{print $1}'`
        cat <<EOF | kubectl create -f - 
        apiVersion: apps.kio.kasten.io/v1alpha1
        kind: RestorePoint
        metadata:
          name: $restorepointcontentname 
          namespace: $ns
        spec:
          restorePointContentRef:
            name: $restorepointcontentname 
EOF
      if [ $? -ne 0 ]; then
         print_error "Error - Failed to create RestorePoint $restorepointcontentname for Namespace $ns"
         exit 1
      fi
  fi
}

# Creates a RestoreAction using the latest RestorePoint
createRestoreAction()
{
   print_info "Creating RestoreAction for Namespace $ns"
   restorepointname=`kubectl get restorepoint -n $ns --no-headers | awk 'NR==1{print $1}'`
   
   cat <<EOF | kubectl create -f - 
        kind: RestoreAction
        apiVersion: actions.kio.kasten.io/v1alpha1
        metadata:
          generateName: restoreaction-$ns-
          namespace: $ns
        spec:
          subject:
            apiVersion: apps.kio.kasten.io/v1alpha1
            kind: RestorePoint
            name: $restorepointname
            namespace: $ns
          targetNamespace: $ns
          # we exclude the storage class
          filters:
            includeResources:
              - group: ""
                version: ""
                resource: rolebindings
                name: ""
                matchExpressions: []
              - group: ""
                version: ""
                resource: resourcequotas
                name: ""
                matchExpressions: []
              - group: ""
                version: ""
                resource: limitranges
                name: ""
                matchExpressions: []
              - group: ""
                version: ""
                resource: roles
                name: ""
                matchExpressions: []        
EOF
restored_namespaces+=($ns)   
}

bulkRestore()
{
for ns in $namespace; do
    print_info "------------------------------------------------" 
    print_heading "Validating Namespace - $ns"
    if [ `kubectl get namespace $ns --no-headers 2>/dev/null | wc -l ` -eq 0 ]
      then
          if [ `kubectl get restorepointcontent -l k10.kasten.io/appNamespace=$ns --no-headers 2>/dev/null | wc -l ` -eq 0 ]
          then
              print_warning "Warning - Namespace and RestorePointContent does not exist for $ns. Skipping the namespace from restore process\n"
          else
             print_info "Namespace $ns does not exist on the cluster, but found a RestorePointContent"
             createNamespace 
             createRPfromRPC 
             createRestoreAction
          fi
    else
          if [ `kubectl get restorepoint -n $ns --no-headers 2>/dev/null | wc -l ` -eq 0 ]
             then
                if [ `kubectl get restorepointcontent -l k10.kasten.io/appNamespace=$ns --no-headers 2>/dev/null | wc -l ` -eq 0 ]
                then
                   print_warning "Warning - Namespace $ns does not have any RestorePoint or RestorePointContent. Skipping the namespace from restore process\n"
                else
                   createRPfromRPC 
                   createRestoreAction
                fi
             else
                   createRestoreAction 
          fi
    fi
done
}

checkRestoreStatus()
{

timeout=0
while [[ $timeout -le $global_timeout && ${#restored_namespaces[@]} -ne 0 ]]
do

restored_namespaces_pending_check=()
for rns in "${restored_namespaces[@]}"
do
   #Get the latest restoreaction name for the namespace
   restoreaction_name=`kubectl get restoreaction -n $rns --no-headers | awk 'NR==1{print $1}'`
   if [ $restoreaction_name ]
   then
       restoreaction_status=`kubectl get restoreaction $restoreaction_name -n $rns -o jsonpath='{.status.state}'`
       if [[ $restoreaction_status == "Complete" ]]; then
           print_info "Restore process completed for Namespace $rns"

       elif [[ $restoreaction_status == "Failed" ]]; then
           print_error "Restore process Failed for Namespace $rns"
           print_error "`kubectl get restoreaction $restoreaction_name -n $rns -o jsonpath='{.status.error}'`"
       else
           restored_namespaces_pending_check+=($rns)
       fi
   fi
done

#print_info "Restore is still in progress for namespaces : ${restored_namespaces_pending_check[*]}"
restored_namespaces=(${restored_namespaces_pending_check[@]})
sleep 5
timeout=$((timeout + 10))

done

if [[ ${#restored_namespaces_pending_check[@]} -ne 0 ]]; then

   print_info "------------------------------------------------"
   print_heading "The timeout for restore status check has been reached"

   #Report status of the namespaces whose restoreaction neither Completed nor failed
   for rns in "${restored_namespaces[@]}"
   do
       restoreaction_name=`kubectl get restoreaction -n $rns --no-headers | awk 'NR==1{print $1}'`
       restoreaction_status=`kubectl get restoreaction $restoreaction_name -n $rns -o jsonpath='{.status.state}'`
       print_warning "Warning - RestoreAction for Namespace $rns is in $restoreaction_status state"
   done
fi

}

#Parse the input parameters 
while getopts s:n:t: flag 
do
    case "${flag}"
        in        
        n) namespace=$(echo ${OPTARG}|sed -e 's/,/ /g')
           ;;
        t) global_timeout=${OPTARG}
           ;;
        *) usageFunction
           ;;
    esac
    no_args="false"
done

if [[ $no_args == "true" || -z $namespace ]] 
then 
   usageFunction
fi

# Specify the timeout in seconds
# The script will check for restored namespaces status until this timeout is reached
if [[ -z $global_timeout ]]; then
        global_timeout=3600
fi

target_cluster_name=`kubectl config current-context`
if [ -z $target_cluster_name ]; then
   print_error "Error - Target kubernetes cluster has not been defined"
   exit 1
else
   print_info "Restore will run on kubernetes cluster: $target_cluster_name"
fi


bulkRestore 

# Check the status of the restored namespaces
if [[ ${#restored_namespaces[@]} -gt 0 ]]; then
        print_info "------------------------------------------------"
        print_heading "Checking the status of restored namespaces...."
        checkRestoreStatus
fi
