class FlashURLHandler
    @xdr: ->
        xdr = new XDomainRequest() if window.XDomainRequest
        return xdr

    @supported: ->
        return !!@xdr()

    @get: (url, cb) ->
        if xmlDocument = new window.ActiveXObject? "Microsoft.XMLDOM"
          xmlDocument.async = false
        else
          return cb()

        xdr = @xdr()
        ranNum = Math.random() * 1000000
        url = [ url, '?cachebreaker=', Math.round ranNum ].join ""
        xdr.open('GET', url)
        xdr.onprogress = ->
            console.log "### xdr progress ###"
        xdr.send()
        xdr.onload = ->
             xmlDocument.loadXML(xdr.responseText)
             cb(null, xmlDocument)

module.exports = FlashURLHandler
