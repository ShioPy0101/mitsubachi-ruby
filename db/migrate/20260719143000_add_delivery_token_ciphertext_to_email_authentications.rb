class AddDeliveryTokenCiphertextToEmailAuthentications < ActiveRecord::Migration[8.1]
  def change
    add_column :email_authentications, :delivery_token_ciphertext, :text
  end
end
