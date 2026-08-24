fx_version 'cerulean'
game 'gta5'

author 'Rico Script'
description 'Server-authoritative RS motorcycle lift integration'
version '1.4.1'

dependency '/onesync'

shared_script 'config.lua'
client_script 'client/main.lua'
server_script 'server/main.lua'

files {
    'stream/rs_moto_lift.ytyp',
    'stream/rs_moto_lift_anim.ycd'
}

data_file 'DLC_ITYP_REQUEST' 'stream/rs_moto_lift.ytyp'
