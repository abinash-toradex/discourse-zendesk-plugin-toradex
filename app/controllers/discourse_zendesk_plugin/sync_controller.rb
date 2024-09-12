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
          comment_body = "#{latest_comment.body}\n\n#{ticket_data_with_image}"
          
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

    # Helper method to format ticket data with image preview and link
    def format_ticket_data(ticket_data)
      if ticket_data.include?('Attachment(s):')
        # Extract attachment URL and file name using regex
        attachment_data = ticket_data.match(/Attachment\(s\):\n(.+?) - (https?:\/\/\S+)/)
        if attachment_data
          file_name = attachment_data[1]
          attachment_url = attachment_data[2]
          # Format in Markdown with an image preview and fallback link
          formatted_data = "#{ticket_data}\n\n![#{file_name}](#{attachment_url})\n[#{file_name}](#{attachment_url})"
          return formatted_data
        end
      end
      ticket_data # Return raw ticket_data if no attachment found
    end
  end
end
