#Netscaler Information
$script:username = "nsroot"
$script:password = "nsroot"
$SG = "svg-HTTPTST"
$LB = "vlb-HTTPTST"
$LBPORT = 80


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


