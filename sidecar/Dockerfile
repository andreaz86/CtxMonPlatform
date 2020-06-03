FROM microsoft/powershell
COPY cpx_tmp.ps1 /tmp
RUN pwsh -c "Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted"
RUN pwsh -c 'install-module netscaler -force -confirm:$false'
ENTRYPOINT ["pwsh", "/tmp/cpx_tmp.ps1"]