URLHandler = require './urlhandler.coffee'
VASTResponse = require './response.coffee'
VASTAd = require './ad.coffee'
VASTUtil = require './util.coffee'
VASTCreativeLinear = require('./creative.coffee').VASTCreativeLinear
VASTCreativeCompanion = require('./creative.coffee').VASTCreativeCompanion
VASTMediaFile = require './mediafile.coffee'
VASTCompanionAd = require './companionad.coffee'

class VASTParser
    URLTemplateFilters = []

    @addURLTemplateFilter: (func) ->
        URLTemplateFilters.push(func) if typeof func is 'function'
        return

    @removeURLTemplateFilter: () -> URLTemplateFilters.pop()
    @countURLTemplateFilters: () -> URLTemplateFilters.length
    @clearUrlTemplateFilters: () -> URLTemplateFilters = []

    @parse: (url, cb) ->
        @_parse url, null, (err, response) ->
            cb(response)

    @_parse: (url, parentURLs, cb) ->

        # Process url with defined filter
        url = filter(url) for filter in URLTemplateFilters

        parentURLs ?= []
        parentURLs.push url

        URLHandler.get url, (err, xml) =>
            return cb(err) if err?

            response = new VASTResponse()

            vastVersion = 2
            unless xml?.documentElement? and xml.documentElement.nodeName is "VAST"
                if xml?.documentElement? and xml.documentElement.nodeName is "VideoAdServingTemplate"
                    vastVersion = 1
                else 
                    return cb()

            for node in xml.documentElement.childNodes
                if node.nodeName is 'Error'
                    response.errorURLTemplates.push (@parseNodeText node)

            for node in xml.documentElement.childNodes
                if node.nodeName is 'Ad'
                    ad = @parseAdElement node, vastVersion
                    if ad?
                        response.ads.push ad
                    else
                        # VAST version of response not supported.
                        VASTUtil.track(response.errorURLTemplates, ERRORCODE: 101)

            complete = =>
                return unless response
                for ad in response.ads
                    return if ad.nextWrapperURL?
                if response.ads.length == 0
                    # No Ad Response
                    # The VAST <Error> element is optional but if included, the video player must send a request to the URI
                    # provided when the VAST response returns an empty InLine response after a chain of one or more wrapper ads.
                    # If an [ERRORCODE] macro is included, the video player should substitute with error code 303.
                    VASTUtil.track(response.errorURLTemplates, ERRORCODE: 303)
                    response = null
                cb(null, response)

            loopIndex = response.ads.length
            while loopIndex--
                ad = response.ads[loopIndex]
                continue unless ad.nextWrapperURL?
                do (ad) =>
                    if parentURLs.length >= 10 or ad.nextWrapperURL in parentURLs
                        # Wrapper limit reached, as defined by the video player.
                        # Too many Wrapper responses have been received with no InLine response.
                        VASTUtil.track(ad.errorURLTemplates, ERRORCODE: 302)
                        response.ads.splice(response.ads.indexOf(ad), 1)
                        complete()
                        return

                    if ad.nextWrapperURL.indexOf('://') == -1
                        # Resolve relative URLs (mainly for unit testing)
                        baseURL = url.slice(0, url.lastIndexOf('/'))
                        ad.nextWrapperURL = "#{baseURL}/#{ad.nextWrapperURL}"

                    @_parse ad.nextWrapperURL, parentURLs, (err, wrappedResponse) =>
                        if err?
                            # Timeout of VAST URI provided in Wrapper element, or of VAST URI provided in a subsequent Wrapper element.
                            # (URI was either unavailable or reached a timeout as defined by the video player.)
                            VASTUtil.track(ad.errorURLTemplates, ERRORCODE: 301)
                            response.ads.splice(response.ads.indexOf(ad), 1)
                        else if not wrappedResponse?
                            # No Ads VAST response after one or more Wrappers
                            VASTUtil.track(ad.errorURLTemplates, ERRORCODE: 303)
                            response.ads.splice(response.ads.indexOf(ad), 1)
                        else
                            response.errorURLTemplates = response.errorURLTemplates.concat wrappedResponse.errorURLTemplates
                            index = response.ads.indexOf(ad)
                            response.ads.splice(index, 1)
                            for wrappedAd in wrappedResponse.ads
                                wrappedAd.errorURLTemplates = ad.errorURLTemplates.concat wrappedAd.errorURLTemplates
                                wrappedAd.impressionURLTemplates = ad.impressionURLTemplates.concat wrappedAd.impressionURLTemplates

                                if ad.trackingEvents?
                                    for creative in wrappedAd.creatives
                                        for eventName in Object.keys ad.trackingEvents
                                            creative.trackingEvents[eventName] or= []
                                            creative.trackingEvents[eventName] = creative.trackingEvents[eventName].concat ad.trackingEvents[eventName]

                                response.ads.splice index, 0, wrappedAd

                        delete ad.nextWrapperURL
                        complete()

            complete()

    @childByName: (node, name) ->
        for child in node.childNodes
            if child.nodeName is name
                return child

    @childsByName: (node, name) ->
        childs = []
        for child in node.childNodes
            if child.nodeName is name
                childs.push child
        return childs


    @parseAdElement: (adElement, version) ->
        for adTypeElement in adElement.childNodes
            if adTypeElement.nodeName is "Wrapper"
                return @parseWrapperElement adTypeElement
            else if adTypeElement.nodeName is "InLine"
                return @parseInLineElement adTypeElement, version

    @parseWrapperElement: (wrapperElement) ->
        ad = @parseInLineElement wrapperElement
        wrapperURLElement = @childByName wrapperElement, "VASTAdTagURI"
        if wrapperURLElement?
            ad.nextWrapperURL = @parseNodeText wrapperURLElement

        wrapperCreativeElement = ad.creatives[0]
        if wrapperCreativeElement? and wrapperCreativeElement.trackingEvents?
            ad.trackingEvents = wrapperCreativeElement.trackingEvents

        if ad.nextWrapperURL?
            return ad

    @parseInLineElement: (inLineElement, version) ->
        ad = new VASTAd()
        if version? and version is 1
            creativeV1 = new VASTCreativeLinear()
            creativeV1.creatives = [];
        for node in inLineElement.childNodes
            switch node.nodeName
                when "Error"
                    ad.errorURLTemplates.push (@parseNodeText node)

                when "Impression"
                    if version? and version is 1 and node.childNodes.length
                        for childNode in node.childNodes
                            switch childNode.nodeName
                                when "URL"
                                    ad.impressionURLTemplates.push ((@parseNodeText childNode).trim())
                    else 
                        ad.impressionURLTemplates.push (@parseNodeText node)

                when "Creatives"
                    for creativeElement in @childsByName(node, "Creative")
                        for creativeTypeElement in creativeElement.childNodes
                            switch creativeTypeElement.nodeName
                                when "Linear"
                                    creative = @parseCreativeLinearElement creativeTypeElement
                                    if creative
                                        ad.creatives.push creative
                                #when "NonLinearAds"
                                    # TODO
                                when "CompanionAds"
                                    creative = @parseCompanionAd creativeTypeElement
                                    if creative
                                        ad.creatives.push creative
                when "TrackingEvents"
                    if creativeV1?
                        creativeV1 = @parseTrackingEventsElement creativeV1, node
                when "Video"
                    if creativeV1?
                        creativeV1= @parseVideoElement creativeV1, node
                when "CompanionAds"
                    if creativeV1?
                        creative =  @parseCompanionAd node
                        ad.creatives.push creative

        if creativeV1?
            ad.creatives.push creativeV1

        return ad

    @parseCreativeLinearElement: (creativeElement) ->
        creative = new VASTCreativeLinear()

        creative = @parseVideoElement creative, creativeElement

        creative = @parseTrackingEventsElement creative, @childsByName(creativeElement, "TrackingEvents")

        return creative

    @parseTrackingEventsElement: (creative, trackingEventsElement) ->
        for trackingEventsElement in trackingEventsElement
            for trackingElement in @childsByName(trackingEventsElement, "Tracking")
                eventName = trackingElement.getAttribute("event")
                trackingURLTemplate = @parseNodeText(trackingElement)
                if eventName? and trackingURLTemplate?
                    creative.trackingEvents[eventName] ?= []
                    creative.trackingEvents[eventName].push trackingURLTemplate

        return creative

    @parseVideoElement: (creative, creativeElement) ->
        creative.duration = @parseDuration @parseNodeText(@childByName(creativeElement, "Duration"))
        if creative.duration == -1 and creativeElement.parentNode.parentNode.parentNode.nodeName != 'Wrapper'
            return null # can't parse duration, element is required

        skipOffset = creativeElement.getAttribute("skipoffset")
        if not skipOffset? then creative.skipDelay = null
        else if skipOffset.charAt(skipOffset.length - 1) is "%"
            percent = parseInt(skipOffset, 10)
            creative.skipDelay = creative.duration * (percent / 100)
        else
            creative.skipDelay = @parseDuration skipOffset

        videoClicksElement = @childByName(creativeElement, "VideoClicks")
        if videoClicksElement?
            creative.videoClickThroughURLTemplate = @parseNodeText(@childByName(videoClicksElement, "ClickThrough"))
            creative.videoClickTrackingURLTemplate = @parseNodeText(@childByName(videoClicksElement, "ClickTracking"))

        for mediaFilesElement in @childsByName(creativeElement, "MediaFiles")
            for mediaFileElement in @childsByName(mediaFilesElement, "MediaFile")
                mediaFile = new VASTMediaFile()
                mediaFile.fileURL = @parseNodeText(mediaFileElement)
                mediaFile.deliveryType = mediaFileElement.getAttribute("delivery")
                mediaFile.codec = mediaFileElement.getAttribute("codec")
                mediaFile.mimeType = mediaFileElement.getAttribute("type")
                mediaFile.bitrate = parseInt mediaFileElement.getAttribute("bitrate") or 0
                mediaFile.minBitrate = parseInt mediaFileElement.getAttribute("minBitrate") or 0
                mediaFile.maxBitrate = parseInt mediaFileElement.getAttribute("maxBitrate") or 0
                mediaFile.width = parseInt mediaFileElement.getAttribute("width") or 0
                mediaFile.height = parseInt mediaFileElement.getAttribute("height") or 0
                creative.mediaFiles.push mediaFile
        return creative

    @parseCompanionAd: (creativeElement) ->
        creative = new VASTCreativeCompanion()

        for companionResource in @childsByName(creativeElement, "Companion")
            companionAd = new VASTCompanionAd()
            companionAd.id = companionResource.getAttribute("id") or null
            companionAd.width = companionResource.getAttribute("width")
            companionAd.height = companionResource.getAttribute("height")
            companionAd.type = companionResource.getAttribute("resourceType")


            codeItems = @childsByName(companionResource, "Code")
            urlItems = @childsByName(companionResource, "URL")
            iframeItems = @childsByName(companionResource, "IFrameResource")
            staticItems = @childsByName(companionResource, "StaticResource")

            if codeItems? && codeItems.length
                for codeElement in codeItems
                    companionAd.staticResource = @parseNodeText(codeElement)
                if !companionAd.type?
                    companionAd.type = 'html'
                # console.log "has xml - code"
            else if urlItems? && urlItems.length
                for urlElement in urlItems
                    companionAd.staticResource = @parseNodeText(urlElement)
                if !companionAd.type?
                    companionAd.type = 'html'
               # console.log "has xml url or other"
            else if iframeItems? && iframeItems.length
                for iframeElement in iframeItems
                    companionAd.staticResource = @parseNodeText(iframeElement)
                if !companionAd.type?
                    companionAd.type = 'iframe'
            else if staticItems? && staticItems.length
                for staticElement in staticItems
                    companionAd.type = staticElement.getAttribute("creativeType") or 0
                    companionAd.staticResource = @parseNodeText(staticElement)

            for trackingEventsElement in @childsByName(companionResource, "TrackingEvents")
                for trackingElement in @childsByName(trackingEventsElement, "Tracking")
                    eventName = trackingElement.getAttribute("event")
                    trackingURLTemplate = @parseNodeText(trackingElement)
                    if eventName? and trackingURLTemplate?
                        companionAd.trackingEvents[eventName] ?= []
                        companionAd.trackingEvents[eventName].push trackingURLTemplate
            companionAd.companionClickThroughURLTemplate = @parseNodeText(@childByName(companionResource, "CompanionClickThrough"))
            creative.variations.push companionAd

        return creative

    @parseDuration: (durationString) ->
        unless (durationString?)
            return -1
        durationComponents = durationString.split(":")
        if durationComponents.length != 3
            return -1

        secondsAndMS = durationComponents[2].split(".")
        seconds = parseInt secondsAndMS[0]
        if secondsAndMS.length == 2
            seconds += parseFloat "0." + secondsAndMS[1]

        minutes = parseInt durationComponents[1] * 60
        hours = parseInt durationComponents[0] * 60 * 60

        if isNaN hours or isNaN minutes or isNaN seconds or minutes > 60 * 60 or seconds > 60
            return -1
        return hours + minutes + seconds

    # Parsing node text for legacy support
    @parseNodeText: (node) ->
        return node and (node.textContent or node.text)

module.exports = VASTParser

