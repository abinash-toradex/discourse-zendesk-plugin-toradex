# frozen_string_literal: true

module DiscourseZendeskPlugin
  class SyncController < ApplicationController
    include ::DiscourseZendeskPlugin::Helper

    requires_plugin ::DiscourseZendeskPlugin::PLUGIN_NAME

    layout false
    before_action :zendesk_token_valid?, only: :webhook
    skip_before_action :check_xhr,
                       :preload_json,
                       :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       only: :webhook

    def webhook
      unless SiteSetting.zendesk_enabled? && SiteSetting.sync_comments_from_zendesk
        return render json: failed_json, status: 422
      end

      ticket_id = params[:ticket_id]
      raise Discourse::InvalidParameters.new(:ticket_id) if ticket_id.blank?
      
      topic = Topic.find_by_id(params[:topic_id])
      raise Discourse::InvalidParameters.new(:topic_id) if topic.blank?
      
      return if !DiscourseZendeskPlugin::Helper.autogeneration_category?(topic.category_id)

      user = User.find_by_email(params[:email]) || Discourse.system_user
      latest_comment = get_latest_comment(ticket_id)
      ticket_data = params[:ticket_data] # Get ticket_data from params

      if latest_comment.present?
        existing_comment =
          PostCustomField.where(
            name: ::DiscourseZendeskPlugin::ZENDESK_ID_FIELD,
            value: latest_comment.id,
          ).first

        if existing_comment.blank?
          # Format ticket_data to include the image preview and link
          ticket_data_with_image = format_ticket_data(ticket_data)
          if ticket_data_with_image.include?(latest_comment.body)
            comment_body = ticket_data_with_image
          else
            comment_body = "#{latest_comment.body}\n\n#{ticket_data_with_image}"
          end
          
          post = topic.posts.create!(user: user, raw: comment_body)
          update_post_custom_fields(post, latest_comment)
        end
      end

      render json: {}, status: 204
    end

    private

    def zendesk_token_valid?
      params.require(:token)

      if SiteSetting.zendesk_incoming_webhook_token.blank? ||
           SiteSetting.zendesk_incoming_webhook_token != params[:token]
        raise Discourse::InvalidAccess.new
      end
    end

    def format_ticket_data(ticket_data)
      cleaned_ticket_data = clean_ticket_data(ticket_data)
      if cleaned_ticket_data.include?('Attachment(s):')
        # Extract attachment names and URLs
        attachment_data = cleaned_ticket_data.scan(/(.+?) - (https?:\/\/\S+)/)
        if attachment_data.any?
          # Format the attachment links as HTML anchor tags
          formatted_attachments = attachment_data.map do |file_name, attachment_url|
            "<a href='#{attachment_url}'>#{file_name}</a>"
          end
          # Embed the formatted attachment links back into the ticket data
          formatted_data = "#{cleaned_ticket_data}\n\n" + formatted_attachments.join("\n")
          return formatted_data
        end
      end
      cleaned_ticket_data
    end
    
    def clean_ticket_data(ticket_data)
      # Remove unnecessary parts from the ticket data
      ticket_data.gsub(/^-+|^\w+ \w+, \w+ \d+, \d{4}, \d{2}:\d{2}/, '').strip
    end
    
    
  end
end
