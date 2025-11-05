# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_06_24_000001) do
  create_table "solid_mcp_messages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "data"
    t.datetime "delivered_at"
    t.string "event_type", limit: 50, null: false
    t.string "session_id", limit: 36, null: false
    t.index ["delivered_at", "created_at"], name: "idx_solid_mcp_messages_on_delivered_and_created"
    t.index ["session_id", "id"], name: "idx_solid_mcp_messages_on_session_and_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "updated_at", null: false
  end
end
