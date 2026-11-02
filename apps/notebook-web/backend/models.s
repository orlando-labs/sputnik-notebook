package models

import orm

export Account, Identity, Project, Membership, NotebookImport
export WebError, AuthenticationRequired, NotFound, Forbidden, InvalidInput

class WebError < Exception:
  attr status
  attr code
  attr message
  def init(@status, @code, @message)
class AuthenticationRequired < WebError:
  def init(): super(401, "authentication_required", "Sign in to continue.")
class NotFound < WebError:
  def init(): super(404, "not_found", "Project or account was not found.")
class Forbidden < WebError:
  def init(): super(403, "forbidden", "This action is not permitted.")
class InvalidInput < WebError:
  def init(message): super(422, "invalid_input", message)

class Account:
  use orm.model(table: :accounts):
    expect_schema:
      column(:id, type: :text, nullable: false, primary_key: true, generated: false)
      column(:name, type: :text, nullable: true)
      column(:state, type: :text, nullable: false)
      column(:created_at, type: :integer, nullable: false)
      column(:updated_at, type: :integer, nullable: false)

class Identity:
  use orm.model(table: :account_identities):
    expect_schema:
      column(:id, type: :text, nullable: false, primary_key: true, generated: false)
      column(:account_id, type: :text, nullable: false)
      column(:provider, type: :text, nullable: false)
      column(:uid, type: :text, nullable: false)
      column(:login, type: :text, nullable: false)
      column(:created_at, type: :integer, nullable: false)
      column(:updated_at, type: :integer, nullable: false)

class Project:
  use orm.model(table: :projects):
    expect_schema:
      column(:id, type: :text, nullable: false, primary_key: true, generated: false)
      column(:owner_account_id, type: :text, nullable: false)
      column(:core_project_id, type: :text, nullable: false)
      column(:title, type: :text, nullable: false)
      column(:created_at, type: :integer, nullable: false)
      column(:updated_at, type: :integer, nullable: false)

class Membership:
  use orm.model(table: :project_memberships):
    expect_schema:
      column(:id, type: :text, nullable: false, primary_key: true, generated: false)
      column(:project_id, type: :text, nullable: false)
      column(:account_id, type: :text, nullable: false)
      column(:role, type: :text, nullable: false)
      column(:created_at, type: :integer, nullable: false)
      column(:updated_at, type: :integer, nullable: false)

class NotebookImport:
  use orm.model(table: :notebook_imports):
    expect_schema:
      column(:id, type: :text, nullable: false, primary_key: true, generated: false)
      column(:account_id, type: :text, nullable: false)
      column(:command_id, type: :text, nullable: false)
      column(:fingerprint, type: :text, nullable: false)
      column(:title, type: :text, nullable: false)
      column(:project_id, type: :text, nullable: false)
      column(:state, type: :text, nullable: false)
