define [
  'i18n!dashboard'
  'compiled/home/views/quickStartBar/BaseItemView'
  'compiled/home/models/quickStartBar/Message'
  'jst/quickStartBar/message'
  'jquery.rails_flash_notifications'
  'jquery.disableWhileLoading'
], (I18n, BaseItemView, Message, template) ->

  class MessageView extends BaseItemView

    template: template

    contextSearchOptions:
      fakeInputWidth: '100%'
      contexts: ENV.CONTEXTS
      placeholder: "Type the name of the person to send this to..."
      selector:
        preparer: (postData, data, parent) ->
          for row in data
            row.noExpand = true
        browser: false

    initialize: ->
      @model or= new Message

    save: (json) ->
      @model.save(json).done ->
        $.flashMessage I18n.t 'message_sent', 'Message Sent'

