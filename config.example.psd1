# Copie este arquivo para config.psd1 e preencha.  /  Copy to config.psd1 and fill in.
#
#   Copy-Item config.example.psd1 config.psd1
#
# config.psd1 e bloqueado pelo .gitignore. NUNCA faca commit dele.
# config.psd1 is gitignored. NEVER commit it.
#
# Os valores vem do README do SEU pacote do EBS. Este repositorio contem
# apenas a automacao -- nenhuma credencial, nenhum link para os dados.
# The values come from YOUR EBS package README. This repository holds only
# the automation -- no credentials, no links to the data.

@{
    # Link da pasta publica do Google Drive com as partes + manifest.txt
    # Public Google Drive folder holding the parts + manifest.txt
    FolderUrl    = 'https://drive.google.com/drive/folders/COLOQUE_O_ID_AQUI'

    # Senha do WebLogic (obrigatoria) / WebLogic password (required)
    WlsPassword  = ''

    # Senha do schema APPS (padrao 'apps') / APPS schema password (defaults to 'apps')
    AppsPassword = 'apps'

    # Hostname que o EBS gravou no contexto / hostname baked into the EBS context
    AppsHost     = 'apps.example.com'

    # Onde instalar / where to install
    TargetDir    = 'D:\R12OnContainer'
}
