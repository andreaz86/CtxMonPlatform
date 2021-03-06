#Netscaler Information
$script:username = "nsroot"
$script:password = "nsroot"
$CS_HTTP ="CS_HTTP"



#For testing connectivty
$login = @{
    login = @{
        username = $username;
        password = $password
    }
}
$loginJson = ConvertTo-Json -InputObject $login


#Wait until CPX is up and available
do
{
    write-host "Waiting for CPX to become available"
    Start-Sleep -Seconds 5
    $localip = invoke-restmethod -uri "http://consul:8500/v1/catalog/service/ctxmonplatform_netscaler-9080" -ErrorAction Continue
    $script:nsip = $localip[0].ServiceAddress
    $nsip_port=$nsip+":9080"

    $testparams = @{
        Uri = "http://$nsip_port/nitro/v1/config/login"
        Method = 'POST'
        Body = $loginJson
        ContentType = 'application/json'
    }

    Write-host "Testing for AUTH on $nsip"
    try {
        $testrest = Invoke-RestMethod @testparams -ErrorAction Continue
    } catch {
        Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
        Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
    }

}UNTIL($testrest.errorcode -eq 0)

write-host "Connecting to CPX at $nsip.."
#Connect to the Netscaler and create session variable
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($Username, $SecurePassword)
$script:Session =  Connect-Netscaler -Hostname $nsip_port -PassThru -Credential $Credential

Enable-NSFeature -name CS -Force
Enable-NSFeature -name RESPONDER -Force

#################   SERVICE GROUP   #########################
write-host "Creating Servicegroup"
New-NSLBServiceGroup -Name "SG_CHECKMK" -Protocol HTTP -Session $Session -ErrorAction Continue -State ENABLED
write-host "SG_CHECKMK"
New-NSLBServiceGroup -Name "SG_KIBANA" -Protocol HTTP -Session $Session -ErrorAction Continue -State ENABLED
write-host "SG_KIBANA"
New-NSLBServiceGroup -Name "SG_PORTAINER" -Protocol HTTP -Session $Session -ErrorAction Continue -State ENABLED
write-host "SG_PORTAINER"

#################   VIRTUAL SERVER ###########################
write-host "Creating VirtualServer"
New-NSLBVirtualServer -Name "VS_CHECKMK" -ServiceType HTTP -NonAddressable -Session $Session 
write-host "VS_CHECKMK"
New-NSLBVirtualServer -Name "VS_KIBANA" -ServiceType HTTP -NonAddressable -Session $Session 
write-host "VS_KIBANA"
New-NSLBVirtualServer -Name "VS_PORTAINER" -ServiceType HTTP -NonAddressable -Session $Session 
write-host "VS_PORTAINER"

################    SERVER  ################################
write-host "Creating Server:"
$checkmk= invoke-restmethod -uri "http://consul:8500/v1/catalog/service/ctxmonplatform_checkmk-5000" -ErrorAction Continue
$kibana= invoke-restmethod -uri "http://consul:8500/v1/catalog/service/ctxmonplatform_kibana" -ErrorAction Continue
$portainer= invoke-restmethod -uri "http://consul:8500/v1/catalog/service/portainer" -ErrorAction Continue
New-NSLBServer -Name CHECKMK -IPAddress $checkmk[0].ServiceAddress -Session $Session -ErrorAction Continue -State ENABLED
write-host "Created server CheckMK with IP" $checkmk[0].ServiceAddress
New-NSLBServer -Name KIBANA -IPAddress $kibana[0].ServiceAddress -Session $Session -ErrorAction Continue -State ENABLED
write-host "Created server Kibana with IP" $kibana[0].ServiceAddress
New-NSLBServer -Name PORTAINER -IPAddress $portainer[0].ServiceAddress -Session $Session -ErrorAction Continue -State ENABLED

##############  ADD SERVER TO SERVICEGROUP  ########################
write-host "Adding server to ServiceGroup:"
New-NSLBServiceGroupMember -Name SG_CHECKMK -ServerName CHECKMK -Session $Session -Port "5000" -ErrorAction SilentlyContinue
write-host "CHECKMK Server added to SG_CHECKMK ServiceGroup"
New-NSLBServiceGroupMember -Name SG_KIBANA -ServerName KIBANA -Session $Session -Port 5601 -ErrorAction SilentlyContinue
write-host "KIBANA Server added to SG_KIBANA ServiceGroup"
New-NSLBServiceGroupMember -Name SG_PORTAINER -ServerName PORTAINER -Session $Session -Port 9000 -ErrorAction SilentlyContinue
write-host "PORTAINER Server added to SG_PORTAINER ServiceGroup"

############### ADD SERVICEGROUP TO VSERVER #######################
write-host "Adding servicegroup to Virtual Server:"
Add-NSLBVirtualServerBinding -VirtualServerName VS_CHECKMK -ServiceGroupName SG_CHECKMK -Session $Session -ErrorAction Continue
write-host "SG_CHECKMK added to VS_CHECKMK"
Add-NSLBVirtualServerBinding -VirtualServerName VS_KIBANA -ServiceGroupName SG_KIBANA -Session $Session -ErrorAction Continue
write-host "SG_KIBANA added to VS_KIBANA"
Add-NSLBVirtualServerBinding -VirtualServerName VS_PORTAINER -ServiceGroupName SG_PORTAINER -Session $Session -ErrorAction Continue
write-host "SG_PORTAINER added to VS_PORTAINER"

############### CREATING CONTENT SWITCHING  #######################
write-host "Creating Content switching vServer:"
New-NSCSVirtualServer -Name CS_HTTP -Session $Session -IPAddress $localip[0].ServiceAddress -Port 80 -ServiceType HTTP -State ENABLED
write-host "Created server on port 80"
New-NSCSVirtualServer -Name CS_HTTPS -Session $Session -IPAddress $localip[0].ServiceAddress -Port 443 -ServiceType SSL -State ENABLED
write-host "Created server on port 443"

############### CREATING CS POLICY  ############################
write-host "Creating Content switching policy:"
New-NSCSPolicy -Name CS_POL_CHECKMK -Rule 'HTTP.REQ.HOSTNAME.EQ("checkmk.lab.local")'
New-NSCSPolicy -Name CS_POL_KIBANA -Rule 'HTTP.REQ.HOSTNAME.EQ("kibana.lab.local")'
New-NSCSPolicy -Name CS_POL_PORTAINER -Rule 'HTTP.REQ.HOSTNAME.EQ("portainer.lab.local")'

#############   ASSIGN CS POLICY TO CS VSERVER  ################
Add-NSCSVirtualServerPolicyBinding -Name CS_HTTPS -PolicyName CS_POL_CHECKMK -TargetLBVServer VS_CHECKMK -Priority 100
Add-NSCSVirtualServerPolicyBinding -Name CS_HTTPS -PolicyName CS_POL_KIBANA -TargetLBVServer VS_KIBANA -Priority 110
Add-NSCSVirtualServerPolicyBinding -Name CS_HTTPS -PolicyName CS_POL_PORTAINER -TargetLBVServer VS_PORTAINER -Priority 120

############# RESPONDER POLICY  ##############################
New-NSResponderAction -name RES_ACT_CHECKMK -Type Redirect -target '"/cmk/check_mk"' -ResponseStatusCode 301
New-NSResponderPolicy -Name RES_POL_CHECKMK -Rule 'HTTP.REQ.URL.EQ("/")' -Action RES_ACT_CHECKMK
New-NSResponderAction -Name CS_ACT_HTTP2HTTPS -Type Redirect -target '"https://" + HTTP.REQ.HOSTNAME.HTTP_URL_SAFE + HTTP.REQ.URL.PATH_AND_QUERY.HTTP_URL_SAFE' -ResponseStatusCode 301
New-NSResponderPolicy -Name CS_POL_HTTP2HTTPS -Rule true -Action CS_ACT_HTTP2HTTPS


Add-NSLBVirtualServerResponderPolicyBinding -PolicyName RES_POL_CHECKMK -Priority 100 -VirtualServerName VS_CHECKMK -Bindpoint REQUEST
Add-NSCSVirtualServerResponderPolicyBinding -PolicyName CS_POL_HTTP2HTTPS -Priority 100 -VirtualServerName CS_HTTP -Bindpoint REQUEST 

Add-NSCertKeyPair -CertKeyName "LabRootCA" -CertPath /nsconfig/ssl/RootCA.cer
$password=ConvertTo-SecureString "Aa123456" -AsPlainText -Force
Add-NSCertKeyPair -CertKeyName "LabWildcard" -CertPath /nsconfig/ssl/lab.local.pfx -CertKeyFormat PFX -Password $password
Add-NSSSLCertificateLink -CertKeyName LabWildcard -IntermediateCertKeyName LabRootCA
Add-NSLBSSLVirtualServerCertificateBinding -VirtualServerName CS_HTTPS -Certificate LabWildcard
