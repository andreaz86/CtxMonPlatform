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

write-host "Creating Servicegroup"
New-NSLBServiceGroup -Name "SG_CHECKMK" -Protocol HTTP -Session $Session -ErrorAction Continue -State ENABLED 
New-NSLBServiceGroup -Name "SG_KIBANA" -Protocol HTTP -Session $Session -ErrorAction Continue -State ENABLED

write-host "Creating VirtualServer"
New-NSLBVirtualServer -Name "VS_CHECKMK" -ServiceType HTTP -NonAddressable -Session $Session 
New-NSLBVirtualServer -Name "VS_KIBANA" -ServiceType HTTP -NonAddressable -Session $Session 

write-host "Creating Server:"
$checkmk= invoke-restmethod -uri "http://consul:8500/v1/catalog/service/ctxmonplatform_checkmk-5000" -ErrorAction Continue
$kibana= invoke-restmethod -uri "http://consul:8500/v1/catalog/service/ctxmonplatform_kibana" -ErrorAction Continue
New-NSLBServer -Name CHECKMK -IPAddress $checkmk[0].ServiceAddress -Session $Session -ErrorAction Continue -State ENABLED
write-host "Created server CheckMK with IP $checkmk[0].ServiceAddress"
New-NSLBServer -Name KIBANA -IPAddress $kibana[0].ServiceAddress -Session $Session -ErrorAction Continue -State ENABLED
write-host "Created server Kibana with IP $kibana[0].ServiceAddress"

write-host "Adding server to ServiceGroup:"
New-NSLBServiceGroupMember -Name SG_CHECKMK -ServerName CHECKMK -Session $Session -Port "5000" -ErrorAction SilentlyContinue
New-NSLBServiceGroupMember -Name SG_KIBANA -ServerName KIBANA -Session $Session -Port 5601 -ErrorAction SilentlyContinue

Add-NSLBVirtualServerBinding -VirtualServerName VS_CHECKMK -ServiceGroupName SG_CHECKMK -Session $Session -ErrorAction Continue
Add-NSLBVirtualServerBinding -VirtualServerName VS_KIBANA -ServiceGroupName SG_KIBANA -Session $Session -ErrorAction Continue

New-NSCSVirtualServer -Name CS_HTTP -Session $Session -IPAddress $localip[0].ServiceAddress -Port 80 -ServiceType HTTP -State ENABLED
New-NSCSVirtualServer -Name CS_HTTPS -Session $Session -IPAddress $localip[0].ServiceAddress -Port 443 -ServiceType SSL -State ENABLED

New-NSCSPolicy -Name CS_POL_CHECKMK -Rule 'HTTP.REQ.HOSTNAME.EQ("checkmk.lab.local")'
New-NSCSPolicy -Name CS_POL_KIBANA -Rule 'HTTP.REQ.HOSTNAME.EQ("kibana.lab.local")'


Add-NSCSVirtualServerPolicyBinding -Name CS_HTTPS -PolicyName CS_POL_CHECKMK -TargetLBVServer VS_CHECKMK -Priority 100
Add-NSCSVirtualServerPolicyBinding -Name CS_HTTPS -PolicyName CS_POL_KIBANA -TargetLBVServer VS_KIBANA -Priority 110

New-NSResponderAction -name RES_ACT_CHECKMK -Type Redirect -target '"/cmk/check_mk"' -ResponseStatusCode 301
New-NSResponderPolicy -Name RES_POL_CHECKMK -Rule 'HTTP.REQ.URL.EQ("/")' -Action RES_ACT_CHECKMK

New-NSResponderAction -Name CS_ACT_HTTP2HTTPS -Type Redirect -target '"https://" + HTTP.REQ.HOSTNAME.HTTP_URL_SAFE + HTTP.REQ.URL.PATH_AND_QUERY.HTTP_URL_SAFE' -ResponseStatusCode 301
New-NSResponderPolicy -Name CS_POL_HTTP2HTTPS -Rule true -Action CS_ACT_HTTP2HTTPS


Add-NSLBVirtualServerResponderPolicyBinding -PolicyName RES_POL_CHECKMK -Priority 100 -VirtualServerName VS_CHECKMK -Bindpoint REQUEST
Add-NSCSVirtualServerResponderPolicyBinding -PolicyName CS_POL_HTTP2HTTPS -Priority 100 -VirtualServerName CS_HTTP -Bindpoint REQUEST 

$password=ConvertTo-SecureString "Aa123456" -AsPlainText -Force
Add-NSCertKeyPair -CertKeyName "LabWildcard" -CertPath /nsconfig/ssl/lab.local.pfx -CertKeyFormat PFX -Password $password
Add-NSLBSSLVirtualServerCertificateBinding -VirtualServerName CS_HTTPS -Certificate LabWildcard
