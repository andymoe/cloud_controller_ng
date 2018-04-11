require 'spec_helper'
require 'actions/route_update'

module VCAP::CloudController
  RSpec.describe RouteUpdate do
    let(:message) { ManifestRoutesUpdateMessage.new({
      routes: [
        { 'route': 'http://potato.tomato.avocado-toast.com:8080/some-path' }
      ]
    })
    }

    let(:user_audit_info) { instance_double(UserAuditInfo).as_null_object }

    describe '#update' do
      let!(:app) { AppModel.make }
      let!(:process) { ProcessModel.make(app: app) }

      context 'when the route already exists' do
        let(:domain) { VCAP::CloudController::SharedDomain.make(name: 'tomato.avocado-toast.com') }
        let!(:route) { Route.make(host: 'potato', domain: domain, path: '/some-path', space: app.space) }

        context 'when the route is already mapped to the app' do
          let!(:route_mapping) {
            RouteMappingModel.make(app: app, route: route, app_port: VCAP::CloudController::ProcessModel::DEFAULT_HTTP_PORT)
          }

          it 'does not attempt to re-map the route to the app' do
            expect {
              RouteUpdate.update(app.guid, message, user_audit_info)
            }.not_to change { route_mapping.reload.updated_at }
          end
        end

        context 'when the route is not mapped to the app' do
          it 'uses the existing route and creates a new mapping' do
            num_routes = Route.count
            num_maps = app.routes.length
            RouteUpdate.update(app.guid, message, user_audit_info)

            routes = app.reload.routes
            expect(routes.length).to eq(num_routes + 0)
            expect(Route.count).to eq(num_maps + 1)

            route = routes.first
            expect(route.host).to eq 'potato'
            expect(route.domain.name).to eq 'tomato.avocado-toast.com'
            expect(route.path).to eq '/some-path'
          end
        end
      end

      context 'when the route does not already exist' do
        context 'when the domain exists' do
          before do
            VCAP::CloudController::SharedDomain.make(name: 'tomato.avocado-toast.com')
          end

          it 'creates and maps the route to the app' do
            expect {
              RouteUpdate.update(app.guid, message, user_audit_info)
            }.to change { app.reload.routes.length }.by(1)
            routes = app.reload.routes
            expect(routes.length).to eq 1

            route = routes.first

            expect(route.host).to eq 'potato'
            expect(route.domain.name).to eq 'tomato.avocado-toast.com'
            expect(route.path).to eq '/some-path'
          end

          context 'when using a wildcard host with a private domain' do
            let(:message) { ManifestRoutesUpdateMessage.new({
              routes: [
                { 'route': 'http://*.private.avocado-toast.com' }
              ]
            })
            }

            before do
              VCAP::CloudController::PrivateDomain.make(owning_organization: app.space.organization, name: 'private.avocado-toast.com')
            end

            it 'creates and maps the route to the app' do
              expect {
                RouteUpdate.update(app.guid, message, user_audit_info)
              }.to change { app.reload.routes.length }.by(1)
              routes = app.reload.routes
              expect(routes.length).to eq 1

              route = routes.first

              expect(route.host).to eq '*'
              expect(route.domain.name).to eq 'private.avocado-toast.com'
            end
          end

          context 'when using a wildcard host with a shared domain' do
            let(:message) { ManifestRoutesUpdateMessage.new({
              routes: [
                { 'route': 'http://*.tomato.avocado-toast.com' }
              ]
            })
            }

            it 'raises an error' do
              expect {
                RouteUpdate.update(app.guid, message, user_audit_info)
              }.to raise_error(CloudController::Errors::ApiError)
            end
          end

          context 'when route creation feature is disabled' do
            before do
              VCAP::CloudController::FeatureFlag.make(name: 'route_creation', enabled: false, error_message: 'nope')
            end

            it 'raises an unauthorized error' do
              expect {
                RouteUpdate.update(app.guid, message, user_audit_info)
              }.to raise_error(CloudController::Errors::ApiError)
            end
          end
        end

        context 'when the domain does not exist' do
          it 'raises a route invalid error' do
            expect {
              RouteUpdate.update(app.guid, message, user_audit_info)
            }.to raise_error(VCAP::CloudController::RouteValidator::RouteInvalid,
              "no domains exist for route #{message.routes.first[:route]}")
          end
        end

        context 'when the organization of the app does not have access to the domain' do
          before do
            VCAP::CloudController::PrivateDomain.make(name: 'tomato.avocado-toast.com')
          end

          it 'raises an error' do
            expect {
              RouteUpdate.update(app.guid, message, user_audit_info)
            }.to raise_error(Route::InvalidOrganizationRelation)
          end
        end
      end

      context 'when multiple domains exist' do
        let!(:specific_domain) { VCAP::CloudController::SharedDomain.make(name: 'tomato.avocado-toast.com') }
        let!(:broader_domain) { VCAP::CloudController::SharedDomain.make(name: 'avocado-toast.com') }

        it 'creates the route in the most specific domain' do
          RouteUpdate.update(app.guid, message, user_audit_info)

          routes = app.reload.routes
          expect(routes.length).to eq(1)
          expect(routes.first.domain.name).to eq specific_domain.name
        end
      end

      context 'when there is no host provided' do
        before do
          VCAP::CloudController::SharedDomain.make(name: 'potato.tomato.avocado-toast.com')
        end

        it('raises an error indicating that a host must be provided') do
          expect {
            RouteUpdate.update(app.guid, message, user_audit_info)
          }.to raise_error(RouteUpdate::InvalidRoute, /host is required for shared-domains/)
        end
      end

      context 'when the host is invalid' do
        let!(:domain) { VCAP::CloudController::SharedDomain.make(name: 'avocado-toast.com') }

        it('raises an error indicating that the host format is invalid') do
          expect {
            RouteUpdate.update(app.guid, message, user_audit_info)
          }.to raise_error(RouteUpdate::InvalidRoute, /host format/)
        end
      end
    end
  end
end
