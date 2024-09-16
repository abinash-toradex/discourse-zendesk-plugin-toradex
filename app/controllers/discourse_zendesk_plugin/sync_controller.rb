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
      # Clean the ticket_data to remove unwanted lines
      cleaned_ticket_data = clean_ticket_data(ticket_data)
    
      # Check if there are attachments to process
      if cleaned_ticket_data.include?('Attachment(s):')
        # Extract all attachments using regex to find multiple files
        attachment_data = cleaned_ticket_data.scan(/(.+?) - (https?:\/\/\S+)/)
    
        if attachment_data.any?
          # Process each attachment
          formatted_attachments = attachment_data.map do |file_name, attachment_url|
            if file_name =~ /\.(png|jpe?g|gif)$/i
              # For image attachments, display only the image
              "![#{file_name}](#{attachment_url})"
            else
              # For non-image attachments (PDF, DOC, etc.), display just the name with a clickable link
              "[#{file_name}](#{attachment_url})"
            end
          end
    
          # Append the formatted attachments to the cleaned ticket_data
          formatted_data = "#{cleaned_ticket_data}\n\n" + formatted_attachments.join("\n")
          return formatted_data
        end
      end
    
      # Return cleaned ticket data if no attachments
      cleaned_ticket_data
    end
    
    # Helper method to clean ticket_data
    def clean_ticket_data(ticket_data)
      # Remove unnecessary lines (like separators and names/times) and trim
      ticket_data.gsub(/^-+|^\w+ \w+, \w+ \d+, \d{4}, \d{2}:\d{2}/, '').strip
    end
    
  end
end
