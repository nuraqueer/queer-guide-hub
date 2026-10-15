___INFO___

{
  "type": "TAG",
  "id": "cvt_temp_public_id",
  "version": 1,
  "securityGroups": [],
  "displayName": "queer.guide Redirects conversions",
  "description": "Record trusted backend lead or sale events with a server-side conversion key. Amounts use major currency units.",
  "containerContexts": [
    "SERVER"
  ]
}

___TEMPLATE_PARAMETERS___

[
  {
    "type": "SELECT",
    "name": "kind",
    "displayName": "Conversion kind",
    "macrosInSelect": false,
    "selectItems": [
      {
        "value": "lead",
        "displayValue": "Lead"
      },
      {
        "value": "sale",
        "displayValue": "Sale"
      }
    ],
    "simpleValueType": true,
    "defaultValue": "lead"
  },
  {
    "type": "TEXT",
    "name": "apiKey",
    "displayName": "Server conversion API key",
    "simpleValueType": true,
    "help": "Keep this in a server container. Grant conversions:write for the selected links only."
  },
  {
    "type": "TEXT",
    "name": "customerExternalId",
    "displayName": "Customer external ID",
    "simpleValueType": true,
    "help": "Stable opaque customer ID; do not use a private email address."
  },
  {
    "type": "TEXT",
    "name": "eventId",
    "displayName": "Stable event ID",
    "simpleValueType": true,
    "help": "Reuse the same ID for retries. Maximum 252 characters."
  },
  {
    "type": "TEXT",
    "name": "eventName",
    "displayName": "Event name",
    "simpleValueType": true,
    "help": "Example: Sign up or Ticket purchase. Maximum 120 characters."
  },
  {
    "type": "TEXT",
    "name": "clickId",
    "displayName": "Attribution click ID (optional)",
    "simpleValueType": true,
    "help": "qg_click_id from the consented visit, or omit after a previously attributed lead."
  },
  {
    "type": "TEXT",
    "name": "amount",
    "displayName": "Sale amount (major currency units)",
    "simpleValueType": true,
    "help": "Use an exact decimal string with at most six decimals. 39.900001 means CHF 39.900001, not cents."
  },
  {
    "type": "TEXT",
    "name": "currency",
    "displayName": "Sale currency",
    "simpleValueType": true,
    "help": "Uppercase three-letter currency, for example CHF."
  },
  {
    "type": "CHECKBOX",
    "name": "trustedBackend",
    "checkboxText": "This event was validated by my backend",
    "simpleValueType": true,
    "defaultValue": false,
    "help": "Do not enable this for unverified browser form submissions or checkout starts."
  },
  {
    "type": "CHECKBOX",
    "name": "analyticsConsent",
    "checkboxText": "Analytics consent is granted for this event",
    "simpleValueType": true,
    "defaultValue": false
  }
]

___SANDBOXED_JS_FOR_SERVER___

const sendHttpRequest = require('sendHttpRequest');
const JSON = require('JSON');
const createRegex = require('createRegex');
const testRegex = require('testRegex');
const getType = require('getType');
function matches(pattern,value){const regex=createRegex(pattern);return regex!==null&&getType(value)==='string'&&testRegex(regex,value);}
function bounded(value,limit){return getType(value)==='string'&&value.trim().length>0&&value.length<=limit;}
if(data.trustedBackend!==true||data.analyticsConsent!==true||!matches('^qg_redirect_[a-f0-9]{64}$',data.apiKey)||!bounded(data.customerExternalId,256)||!bounded(data.eventId,252)||!bounded(data.eventName,120)||(data.kind!=='lead'&&data.kind!=='sale')){data.gtmOnFailure();return;}
const body={customerExternalId:data.customerExternalId,eventId:'gtm:'+data.eventId,eventName:data.eventName};
if(data.clickId){if(!matches('^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$',data.clickId)){data.gtmOnFailure();return;}body.clickId=data.clickId;}
if(data.kind==='sale'){if(!matches('^[0-9]{1,12}(\\.[0-9]{1,6})?$',data.amount)||!matches('^[A-Z]{3}$',data.currency)){data.gtmOnFailure();return;}body.amount=data.amount;body.currency=data.currency;}
return sendHttpRequest('https://queer.guide/api/redirects/track/'+data.kind,{method:'POST',timeout:10000,headers:{'Content-Type':'application/json',Authorization:'Bearer '+data.apiKey}},JSON.stringify(body)).then(result=>{if(result.statusCode>=200&&result.statusCode<300)data.gtmOnSuccess();else data.gtmOnFailure();},()=>data.gtmOnFailure());

___SERVER_PERMISSIONS___

[
  {
    "instance": {
      "key": {
        "publicId": "send_http",
        "versionId": "1"
      },
      "param": [
        {
          "key": "allowedUrls",
          "value": {
            "type": 1,
            "string": "specific"
          }
        },
        {
          "key": "urls",
          "value": {
            "type": 2,
            "listItem": [
              {
                "type": 1,
                "string": "https://queer.guide/api/redirects/track/lead"
              },
              {
                "type": 1,
                "string": "https://queer.guide/api/redirects/track/sale"
              }
            ]
          }
        }
      ]
    },
    "isRequired": true
  }
]

___TESTS___

scenarios:
- name: Missing backend validation blocks transmission
  code: |-
    mock('sendHttpRequest', function(){fail('Unexpected transmission');});
    runCode({trustedBackend:false,analyticsConsent:true});
    assertApi('gtmOnFailure').wasCalled();
- name: Missing consent blocks transmission
  code: |-
    mock('sendHttpRequest', function(){fail('Unexpected transmission');});
    runCode({trustedBackend:true,analyticsConsent:false});
    assertApi('gtmOnFailure').wasCalled();

___NOTES___

Requires server container image 2.0.0 or newer for RE2 validation. Import into a SERVER container. Keep the API key out of web-container tags.
